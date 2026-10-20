# OpenCV

Glance 的前景特徵與幾何配對使用 OpenCV 5.0.0 官方 iOS 靜態 framework。OpenCV 採 Apache-2.0；完整條文與著作權列於本目錄 LICENSE／COPYRIGHT，隨 App 資源附帶。Glance 的 MIT 授權不取代第三方條款。Apple Vision 由系統提供。

官方來源：https://github.com/opencv/opencv/tree/5.0.0
官方發行包：https://github.com/opencv/opencv/releases/download/5.0.0/opencv-5.0.0-ios-framework.zip
ZIP SHA-256：c844d3466f7999b6e920d4ee53c71310c4cdd34b13f1547f373723834e308b0e

發行包本身不提交 Git；使用 Scripts/prepare-opencv.py 驗證並取得。橋接由 Glance 修改為固定前景 ORB：全圖灰階提取後，依 Apple 中央前景遮罩篩選特徵，移除 SIFT 選项及影像hash紀錄。OpenCV 本體未修改。PrivacyInfo.xcprivacy 沿用官方 framework 資源。

已依官方 iOS arm64 build information 核對隨包組件：libprotobuf、libjpeg-turbo、libwebp、libpng、zlib、KleidiCV，以及內建 FlatBuffers／MLAS；各自授權及必要著作權文字保留在 components，來源與hash列於 components.json。KleidiCV 26.03 封存另核 OpenCV cmake 鎖定MD5並記SHA-256。libjpeg-turbo 同時保留 README.ijg 與完整授權，This software is based in part on the work of the Independent JPEG Group。實際連入App的子集依靜態連結器決定，不因此刪減隨包聲明。
