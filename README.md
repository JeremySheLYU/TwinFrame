# 雙鏡 TwinFrame

用 iPhone 15 Pro Max 拍下眼前的場景，也把自己的反應放進同一個畫面。這是一個 SwiftUI / AVFoundation 原生 iPhone 專案，最低系統為 iOS 17。

## 安裝到你的 iPhone

1. 在 Mac 的 App Store 安裝 [Xcode](https://apps.apple.com/app/xcode/id497799835)。第一次開啟時安裝 iOS 平台元件。Xcode 的版本須支援手機目前的 iOS。
2. 在 GitHub 選 **Code → Download ZIP**，解壓縮專案，雙擊 `TwinFrame.xcodeproj`。在 Xcode → Settings → Apple Accounts 登入自己的 Apple 帳戶。
3. 用 USB-C 線連接並解鎖 iPhone，在手機上點「信任」。開始配對後，到 iPhone「設定 → 私隱與保安（或隱私權與安全性）→ 開發者模式」，開啟後依提示重新啟動並確認。
4. 在 Xcode 左欄點藍色 TwinFrame 專案，選 TARGETS 下的 TwinFrame → Signing & Capabilities。勾選 Automatically manage signing，Team 選自己的團隊或 Personal Team。如果 Xcode 提示 Bundle Identifier 已被使用，把它改成自己的唯一識別碼。
5. 在 Xcode 上方的執行裝置選你的 iPhone 15 Pro Max，按 **⌘R**。手機會開啟「雙鏡」。安裝成功後可拔線，從手機主畫面使用。

免費 Apple 帳戶可以用 Personal Team 在自己的手機試用。簽署描述檔自建立起有效七天，到期後用同一帳戶和識別碼再次按 ⌘R 即可。雙鏡硬體須在真機上測試。

## 拍攝

- 打開「雙鏡」，允許相機。錄影想保留聲音時也允許麥克風。拒絕麥克風後可以繼續拍照或錄製無聲影片。
- 直握手機。預設後鏡頭為主畫面，自拍在右上角，前鏡頭呈鏡像。想把自己的表情放大，拍攝前點右下方的交換鏡頭按鈕。
- 選「拍照」，按白色快門，將當下的雙鏡畫面存為一張 JPEG。
- 選「錄影」，按紅色快門開始，按方形停止。錄影時會顯示經過時間。切到背景或遇到相機中斷時，App 會嘗試結束並保存已錄到的片段。
- 第一次儲存時可以允許「加入照片」。若沒有照片權限，或「照片」未能匯入，可在「檔案 → 瀏覽 → 我的 iPhone → 雙鏡 → Captures」找到拍攝結果。

## 輸出

| 項目 | 格式 |
| --- | --- |
| 照片 | 720 × 1280 JPEG，取自拍攝時的雙鏡合成影格 |
| 影片 | 720 × 1280 直式 MOV，H.264，目標 30 fps；依硬體負載可降至 24 fps |
| 錄音 | 麥克風可用且已允許時，寫入 AAC 單聲道 |
| 構圖 | 主畫面加右上角畫中畫，兩個鏡頭合成一個檔案 |

相機畫面與聲音均在裝置上處理。App 本身無需帳戶、網路服務或第三方套件。

## 驗證狀態

完整 Swift 程式已用 Apple 的 Mac Catalyst 17 目標完成編譯與連結，並檢查了拍攝前的空畫面、鏡頭影格時間差、裁切位置和錄影錯誤恢復。這次環境缺少完整 Xcode 與 iPhoneOS SDK。iPhone 版的實機安裝、雙鏡實拍、照片寫入和有聲影片回放仍待驗證。

## 第一次真機試拍

1. 後鏡頭對著桌面，自己在前鏡頭揮手。確認兩邊同時更新，拍一張照片，到「照片」核對畫中畫位置和方向。
2. 交換主副鏡頭，錄一段約十秒的影片。一邊移動後鏡頭，一邊在自拍畫面說話或拍手；回放時檢查兩邊動作和聲音。
3. 再開始一段錄影並切回主畫面，重開 App，確認上一段影片已保存且可重新取景。

Apple 文件：[在真機執行 App](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) · [啟用開發者模式](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) · [Personal Team 簽署](https://developer.apple.com/help/account/basics/about-your-developer-account) · [前後鏡頭同錄](https://developer.apple.com/documentation/avfoundation/avmulticampip-capturing-from-multiple-cameras)

## 開源授權

本專案採用 [MIT License](LICENSE)。
