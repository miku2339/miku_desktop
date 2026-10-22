# 網站部署

- 公開網址：<https://miku.qimake.com/>
- 來源：`website/`，只發布此目錄的靜態檔案。
- 主機：`vps-us`，目錄 `/home/233/apps/miku-desktop-site/`。
- Nginx：以使用者 `233` 執行，監聽 `127.0.0.1:8810`。
- Cloudflare：`qixi-blog-us` Tunnel 的獨立 hostname ingress，DNS 開啟代理。

更新時先上傳至新的 `releases/<時間>/`，核對 SHA-256，再原子切換 `current`；`previous` 保留上一版。Nginx 的 `root` 經由符號連結讀取，不需重啟共用服務。

`guard.sh` 由使用者 crontab 於開機及每分鐘執行，只管理本站的 Nginx 程序。

回退時核對 `previous` 後，把 `current` 原子切回該目錄。首次部署前沒有上一版；下線需移除本站 DNS、Tunnel ingress、兩條 crontab 工作，並向本站 PID 發送 `QUIT`。
