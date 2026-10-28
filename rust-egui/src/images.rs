// Image files on disk.
// A recipe's image_path is a path to a file, usually a copy inside
// the images/ directory next to recipes.db. Importing copies the
// chosen file there, so the recipe keeps working if the original
// file is later moved or deleted. It never overwrites an existing
// file: a second import of the same filename gets a _1, _2 suffix.
use std::fs;
use std::path::Path;

pub(crate) fn import_image(source: &Path) -> Result<String, String> {
    let filename = source
        .file_name()
        .ok_or_else(|| "Chosen file has no filename.".to_string())?;
    let images_dir = Path::new("images");
    fs::create_dir_all(images_dir)
        .map_err(|err| format!("Could not create images directory: {}", err))?;

    let dest = images_dir.join(filename);
    // Already the stored copy: nothing to do.
    if dest == source {
        return Ok(dest.to_string_lossy().to_string());
    }
    if dest.exists() {
        let stem = source
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "image".to_string());
        let extension = source.extension().map(|s| s.to_string_lossy().to_string());
        let mut counter = 1;
        loop {
            let candidate_name = match &extension {
                Some(ext) => format!("{}_{}.{}", stem, counter, ext),
                None => format!("{}_{}", stem, counter),
            };
            let candidate = images_dir.join(candidate_name);
            if !candidate.exists() {
                fs::copy(source, &candidate)
                    .map_err(|err| format!("Could not copy image: {}", err))?;
                return Ok(candidate.to_string_lossy().to_string());
            }
            counter += 1;
        }
    }
    fs::copy(source, &dest).map_err(|err| format!("Could not copy image: {}", err))?;
    Ok(dest.to_string_lossy().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    #[test]
    fn import_copies_and_renames_on_collision() {
        // Serialise with the DB tests: both switch the process
        // working directory, which is process-global (see db.rs).
        // Assertions below are unchanged.
        let _cwd_lock = crate::db::CWD_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let tmp = env::temp_dir().join(format!("image-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let original = env::current_dir().unwrap();
        env::set_current_dir(&tmp).unwrap();

        let source = Path::new("photo.png");
        fs::write(source, b"fake-image-bytes").unwrap();

        let first = import_image(source).unwrap();
        assert_eq!(first, "images/photo.png");
        assert_eq!(fs::read("images/photo.png").unwrap(), b"fake-image-bytes");

        let second = import_image(source).unwrap();
        assert_eq!(second, "images/photo_1.png");
        assert_eq!(fs::read("images/photo_1.png").unwrap(), b"fake-image-bytes");

        // A file already inside images/ is used as-is, not copied again.
        let already = import_image(Path::new("images/photo.png")).unwrap();
        assert_eq!(already, "images/photo.png");

        env::set_current_dir(original).unwrap();
        let _ = fs::remove_dir_all(&tmp);
    }
}
