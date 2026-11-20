//! Memory photographs contain only the two WebView2 surfaces owned by this app.

#[cfg(windows)]
use crate::{integration::Services, layers, Shell};
#[cfg(windows)]
use serde_json::json;
use serde_json::Value;
use tauri::AppHandle;
#[cfg(windows)]
use tauri::Manager;

#[cfg(windows)]
async fn surface(window: tauri::WebviewWindow) -> Result<Vec<u8>, String> {
    use std::sync::{Arc, Mutex};
    use webview2_com::{
        CapturePreviewCompletedHandler,
        Microsoft::Web::WebView2::Win32::COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG,
    };
    use windows::Win32::{
        Foundation::HGLOBAL,
        System::Com::{
            StructuredStorage::CreateStreamOnHGlobal, STATFLAG_NONAME, STATSTG, STREAM_SEEK_SET,
        },
    };
    let (sender, receiver) = tokio::sync::oneshot::channel();
    let sender = Arc::new(Mutex::new(Some(sender)));
    window
        .with_webview(move |view| {
            let response = sender.clone();
            let result = (|| -> windows::core::Result<()> {
                let stream = unsafe { CreateStreamOnHGlobal(HGLOBAL::default(), true)? };
                let saved = stream.clone();
                let callback = CapturePreviewCompletedHandler::create(Box::new(move |status| {
                    let result = (|| -> Result<Vec<u8>, String> {
                        status.map_err(|error| error.to_string())?;
                        let mut info = STATSTG::default();
                        unsafe {
                            saved
                                .Stat(&mut info, STATFLAG_NONAME)
                                .map_err(|error| error.to_string())?;
                        }
                        if info.cbSize == 0 || info.cbSize > 32 * 1024 * 1024 {
                            return Err("照片大小不適合儲存".into());
                        }
                        let mut bytes = vec![0; info.cbSize as usize];
                        let mut read = 0;
                        unsafe {
                            saved
                                .Seek(0, STREAM_SEEK_SET, None)
                                .map_err(|error| error.to_string())?;
                            saved
                                .Read(
                                    bytes.as_mut_ptr().cast(),
                                    bytes.len() as u32,
                                    Some(&mut read),
                                )
                                .ok()
                                .map_err(|error| error.to_string())?;
                        }
                        if read as usize != bytes.len() {
                            return Err("照片未完整擷取".into());
                        }
                        Ok(bytes)
                    })();
                    if let Some(sender) = crate::lock(&response).take() {
                        let _ = sender.send(result);
                    }
                    Ok(())
                }));
                unsafe {
                    view.controller().CoreWebView2()?.CapturePreview(
                        COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG,
                        &stream,
                        &callback,
                    )
                }
            })();
            if let Err(error) = result {
                if let Some(sender) = crate::lock(&sender).take() {
                    let _ = sender.send(Err(error.to_string()));
                }
            }
        })
        .map_err(|error| error.to_string())?;
    tokio::time::timeout(std::time::Duration::from_secs(15), receiver)
        .await
        .map_err(|_| "照片擷取逾時，請稍後再試".to_string())?
        .map_err(|_| "照片擷取已中止".to_string())?
}

pub async fn capture(app: &AppHandle) -> Result<Value, String> {
    #[cfg(not(windows))]
    {
        let _ = app;
        return Err("照片擷取需要 Windows WebView2".into());
    }
    #[cfg(windows)]
    {
        let windows = app.webview_windows();
        let (background_label, background) = windows
            .iter()
            .find(|(name, _)| name.starts_with(layers::BACKGROUND_PREFIX))
            .map(|(name, value)| (name.clone(), value.clone()))
            .ok_or("桌面背景尚未就緒")?;
        let surface_id = background_label
            .strip_prefix(layers::BACKGROUND_PREFIX)
            .unwrap();
        let character = windows
            .get(&format!("{}{surface_id}", layers::CHARACTER_PREFIX))
            .cloned()
            .ok_or("角色尚未就緒")?;
        let background = surface(background).await?;
        let character = surface(character).await?;
        let bytes = compose(&background, &character)?;
        let data_dir = app.state::<Shell>().data_dir.clone();
        let folder = data_dir.join("album");
        std::fs::create_dir_all(&folder).map_err(|_| "無法建立相簿資料夾")?;
        let image_name = format!("{}.jpg", uuid::Uuid::new_v4());
        let file = folder.join(&image_name);
        std::fs::write(&file, bytes).map_err(|_| "無法儲存照片")?;
        let scene = crate::lock(&app.state::<Shell>().settings)
            .selected_scene
            .clone();
        let payload = json!({"imageName":image_name,"scene":scene,"capturedAt":chrono::Utc::now().to_rfc3339(),"title":"","note":"","category":"everyday"});
        match app
            .state::<Services>()
            .companion
            .action("album_add_capture", payload)
        {
            Ok(value) => Ok(value),
            Err(error) => {
                let _ = std::fs::remove_file(file);
                Err(error)
            }
        }
    }
}

fn compose(background: &[u8], character: &[u8]) -> Result<Vec<u8>, String> {
    let background = image::load_from_memory(background).map_err(|_| "無法讀取背景照片")?;
    let character = image::load_from_memory(character).map_err(|_| "無法讀取角色照片")?;
    if background.width() == 0
        || background.height() == 0
        || background.dimensions() != character.dimensions()
    {
        return Err("背景與角色的照片尺寸不一致".into());
    }
    let limit = background.width().max(background.height()).min(2560);
    let mut background = background.thumbnail(limit, limit).to_rgba8();
    let character = character.thumbnail(limit, limit).to_rgba8();
    if !character.pixels().any(|pixel| pixel.0[3] > 0) {
        return Err("角色尚未出現在照片中".into());
    }
    image::imageops::overlay(&mut background, &character, 0, 0);
    let image = image::DynamicImage::ImageRgba8(background).to_rgb8();
    let mut bytes = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, 85)
        .encode_image(&image)
        .map_err(|_| "無法編碼照片")?;
    Ok(bytes)
}

use image::GenericImageView;

#[cfg(test)]
mod tests {
    use super::*;
    fn png(width: u32, height: u32, pixel: [u8; 4]) -> Vec<u8> {
        let image = image::RgbaImage::from_pixel(width, height, image::Rgba(pixel));
        let mut bytes = std::io::Cursor::new(Vec::new());
        image.write_to(&mut bytes, image::ImageFormat::Png).unwrap();
        bytes.into_inner()
    }
    #[test]
    fn composites_owned_surfaces_and_rejects_empty_characters() {
        let background = png(3, 3, [255, 255, 255, 255]);
        let character = png(3, 3, [0, 0, 0, 255]);
        let photo = image::load_from_memory(&compose(&background, &character).unwrap()).unwrap();
        assert_eq!(photo.dimensions(), (3, 3));
        assert!(compose(&background, &png(3, 3, [0, 0, 0, 0])).is_err());
        assert!(compose(&background, &png(2, 3, [0, 0, 0, 255])).is_err());
    }
}
