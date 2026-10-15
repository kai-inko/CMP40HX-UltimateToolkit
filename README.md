Gặp lỗi và cần báo cáo sửa lỗi? [Vào đường link này sau đó nhấn vào **New Issue** để báo cáo](https://github.com/kai-inko/CMP40HX-UltimateToolkit-Indie/issues)
#

Dựa theo bản gốc chạy trên 30HX của Lâm Đặng - https://www.facebook.com/lamdang99/ 

Fork từ bản chạy 40HX của lavievn - https://github.com/lavievn/CMP40HX-DriverToggle, bản Unlock PCIe 2.0 40hx của Cyridd - https://github.com/Cyridd/cmpunlocker, và bản chọn GPU mặc định của nethe-GitHub https://github.com/nethe-GitHub/select_default_GPU

# CMP 40HX Ultimate Toolkit - by kai-inko

Công cụ Windows (PowerShell/WinForms) chuyển đổi giữa **hai gói driver NVIDIA CMP 40HX** đã được người dùng tự chuẩn bị. Chỉ hỗ trợ thiết bị có Hardware ID `PCI\VEN_10DE&DEV_1F0B`.

Thêm mới tính năng và cả UI của bản Unlock PCIe 2.0, thêm cả tính năng chọn GPU mặc định.

> **Cảnh báo:**
> 
  > Việc cài lại driver có thể làm gián đoạn GPU, gây màn hình đen hoặc yêu cầu khởi động lại. Không đảm bảo chuyển đổi không cần khởi động lại. Hãy sao lưu dữ liệu, tạo điểm khôi phục Windows và tự chịu trách nhiệm khi sử dụng.
> 
  > Unlock PCIe Gen 2.0 sẽ mở khóa hiệu năng cho máy, nhưng sẽ kèm theo một số lỗi trong vài trường hợp nhất định. Hãy cân nhắc trước khi sử dụng.
## Tính năng

- Hai hồ sơ: **Làm việc/AI** và **Chơi game/LOL**.
- Chọn **thư mục driver**, công cụ tự tìm INF thuộc lớp `Display`, có khai báo cài đặt 64-bit cho `DEV_1F0B` và trường `DriverVer`.
- Nếu thư mục chứa nhiều INF phù hợp, công cụ từ chối chọn ngẫu nhiên.
- Giao diện WinForms, kiểm tra trạng thái và mô phỏng kiểm thử không thay đổi driver thật.
- Tạo shortcut Desktop/Start Menu bằng script; không kèm launcher EXE hay hình ảnh, QR hoặc chức năng quyên góp.

## Yêu cầu

- Windows 10/11 64-bit, PowerShell 5.1, quyền quản trị khi chuyển driver thật.
  - Ấn chuột phải chạy bằng Run as Administrator.
    
~~- Hai gói driver **đã giải nén đầy đủ**, không chứa trong repo này.~~
  ~~- Tải driver của Dartraiden ở [đây](https://github.com/dartraiden/NVIDIA-patcher/releases#release-617.14).~~
  ~~- Tải driver của HieuPC ở [đây](https://drive.google.com/file/d/1Fb1f0PYQoxH6Vz12mbQ9nNGu_m3utDLS/view?usp=sharing).~~
  ~~- [(còn đây là file exe driver LOL chưa giải nén nếu bạn cần)](https://drive.google.com/file/d/1C3SMjR3-z-X_-mlLODiBNfg37YQXz292/view?usp=sharing).~~
  
- INF trong mỗi thư mục phải thực sự hỗ trợ `PCI\VEN_10DE&DEV_1F0B` qua mục `.NTamd64`; việc có mã thiết bị **không tự chứng minh** rằng gói driver tương thích hoặc có chữ ký hợp lệ.
  - Nôm na là phải cài trước Driver 617.14 hoặc 460.89 như trên thì phần mềm mới nhận được.
- Với Unlocker, chỉ dùng được cho bản **Làm việc/AI**
  - **Chơi game/LOL hoàn toàn KHÔNG HỖ TRỢ**.

## Sử dụng

### Hướng dẫn ~~tải về~~
~~1. Tải hai file driver cần thiết và **giải nén** theo hướng dẫn sẵn có của từng phần mềm.~~
~~2. Tải Toolkit: Ấn vào nút **Code - > Download ZIP**. Giải nén toolkit sau khi đã tải về vào nơi cố định (khuyến khích ổ đĩa C:/).~~
~~3. Chuyển 2 thư mục driver đã giải nén **vào folder toolkit** (chung nơi với 2 folder *cmpunlocker* và *simulation-fixtures*).~~

1. Chạy `Chay-CMP40HX-DriverToggle.cmd` hoặc `Chay-CMP40HX-DriverToggle.vbs`.

### Đối với tab Tải driver
1. Ấn vào nút **Tải về bản mới nhất** để tải file về từ các repo.
2. Ấn nút **Kiểm tra và tải về** mục còn thiếu để tải tiếp những mục còn thiếu.
>Khi không nhận diện được driver và unlocker, ứng dụng sẽ tạm khóa cho đến khi phát hiện file trong lần mở lên tiếp theo.

### Đối với tab Chuyển Driver

1. Trong **Thiết lập driver**, chọn thư mục gói driver **Làm việc** và **Chơi game**; công cụ tự tìm INF.
2. Kiểm tra hai hồ sơ và phiên bản nhận diện đúng trước khi thực hiện chuyển.
3. Đóng ứng dụng dùng GPU, đánh dấu xác nhận và mới bấm nút chuyển.
4. Nếu Windows yêu cầu, phải khởi động lại.

Ví dụ từ máy kiểm thử của người dùng (không phải tên file bắt buộc):

| Hồ sơ | INF tìm thấy trong gói |
| --- | --- |
| Làm việc / AI | `Display.Driver\nvaci.inf` (bộ 617.14 đã mod) |
| Chơi game | `Display.Driver\nvaei.inf` (bộ 460.89 đã mod) |

### Đối với tab GPU mặc định
1. Ấn vào **Quét lại danh sách GPU** để tải lại thông tin driver vừa cài
2. Đối với chỉ Windows 11, ấn vào **Mở cài đặt đồ họa Windows** để cài GPU mặc định.
3. Đối với Windows 10 (hoặc cả 11), chọn vào **card 40HX (2060 SUPER hoặc 2070 HIEUPC)** ở bảng phía trên, sau đó nhấn **Đặt làm GPU hiệu năng cao**.
4. Làm tương tự với nút **Đặt làm ICD OpenGL mặc định**, sau đó **Restart**.

### Đối với tab Unlocker

1. Chắc chắn rằng bạn đang sử dụng bản 617.14 (Làm việc/AI).
2. Tick vào tất cả các ô ; sau đó ấn vào **Cài đặt toàn bộ**.
3. Sau khi hiện lên pop-up Installation complete, **SHUTDOWN máy (KHÔNG restart)**.
4. Tùy vào máy, **ấn nút F2, F12, Del,...** để vào UEFI(BIOS).
5. Sang phần **Boot**, đưa **40HX Unlock làm lựa chọn đầu tiên** và restart.
6. Vào máy, vẫn chạy `Chay-CMP40HX-DriverToggle.cmd` và vào lại tab Unlocker, ấn vào **40HXCheck** để kiểm tra đã mở khóa 2.0 chưa.
7. Nếu chưa thì ấn vào **Run Gen 2 and install auto-start**
8. Muốn gỡ cài đặt Unlocker để cài Driver LOL, ấn vào **40HXUninstall**. **Restart** sau khi gỡ cài đặt.

>Lưu ý: Khi đã chọn driver Chơi game/LOL, phần mềm sẽ tự động khóa Unlocker.

~~## Mô phỏng và kiểm tra trước khi dùng thật~~

~~Chạy `KiemThu-MoPhong.cmd` hoặc trực tiếp:~~

~~```powershell~~
~~powershell.exe -NoProfile -File .\CMP40HX-DriverToggle.ps1 -Simulation -SelfTest~~
~~powershell.exe -NoProfile -File .\CMP40HX-DriverToggle.ps1 -ScanFolder 'C:\duong-dan\driver-da-giai-nen'~~
~~```~~
~~Lệnh `-ScanFolder` chỉ quét INF. File trong `simulation-fixtures/` là dữ liệu thử **không phải driver thật**.~~

~~**Cảnh báo**: chế độ thử nghiệm của Unlocker và default GPU chưa được kiểm chứng, tác giả không chịu trách nhiệm với bất kì thiệt hại nào.~~

## Bảo mật, riêng tư và giới hạn

- Mã PowerShell, VBS, CMD được công bố để kiểm tra; không kèm driver NVIDIA, chương trình EXE.
- Ứng dụng có thể yêu cầu nâng quyền, chạy PowerShell ẩn qua VBS và dùng Windows SetupAPI để chuyển driver. Những hành vi này có thể bị hệ thống bảo mật cảnh báo; cảnh báo không tự chứng minh có mã độc, việc quét không đảm bảo phần mềm tuyệt đối an toàn.
- Không đưa lên GitHub các file `cmp40hx-profiles*.json`, `cmp40hx-*.log`, `*.invalid-*`, driver mod và gói cài riêng vì có thể chứa đường dẫn máy, log hoặc file không được phép phân phối.
~~- **Chưa kiểm thử trực tiếp bản công khai đã lược bỏ thành phần đồ họa trên Windows/CMP 40HX.** Phải thử mô phỏng và xác nhận giao diện trước khi chuyển driver thật.~~

## Cập nhật 16/10/2026
- Thông tin chi tiết nằm trong bản cập nhật 1.9.0 và 1.9.1.

## Cập nhật 12/10/2026
- Đã thành công sửa lỗi WSH compilation error 800A0408 của VBScript.

## Cập nhật 11/10/2026
- Đã thử nghiệm bằng bản mới nhất (617.14) của Dartraiden và bản LOL (460.89) của HieuPC.
- Thêm vào 2 chức năng: chọn GPU mặc định và Unlock PCIe 2.0.

## Định hướng phát triển

- 1.7.0: Sửa lỗi VBScript vĩnh viễn. (Đã hoàn thành)
- 1.8.0: Tích hợp tải về các phần mềm Driver, tải về driver tùy chọn, ~~sẽ thêm bản 460.89 của Raincandy nếu khả thi.~~ (Đã hoàn thành)
- 1.9.0: Tích hợp các phần mềm Unlocker, cải thiện dịch thuật và hiển thị log cho GPU mặc định. (Đã hoàn thành)
- 2.0.0: Tích hợp tất cả vào 1 phần mềm .exe duy nhất và tự động bổ sung cập nhật dựa trên từng tab phần mềm và driver.

## Nguồn và bản quyền

Đây là mã công cụ hỗ trợ quản trị driver, **không liên kết với NVIDIA, Riot Games hay Microsoft**. Không bao gồm gói driver bên thứ ba. Chưa ấn định giấy phép nguồn mở; cần xác minh quyền sử dụng mã gốc trước khi cấp giấy phép phân phối/sửa đổi.
