# Lunch HTTP Server Releases 约束

- 本仓库是 HTTPServer 后端公开发布仓库，只用于安装脚本、manifest、加密后的 release 资产和校验文件。
- 禁止提交 HTTPServer 源码、未加密二进制、私钥、token、ARL、p8、发布密码或任何运行时数据。
- `.release-password` 只用于本机人工测试或安装脚本读取，必须保持在 `.gitignore` 中，不得提交。
- release 资产必须由私有源码仓库 GitHub Actions 构建、压缩、加密后上传；公开仓库不得保存未加密 `.tar.gz`。
- `main` 分支对应稳定通道，`debug` 分支对应调试通道；manifest 路径固定为 `manifests/http-server/{stable,debug}.json`。
- 安装脚本只负责下载 manifest、校验 encrypted sha256、解密、安装 systemd 服务；不要在脚本中包含源码构建逻辑。
- README 可保留在本地用于记录安装方式，但不能上传 GitHub；README 类文件必须加入 `.gitignore`。
- 安装脚本不得内置 release 密码。安装时必须由环境变量、服务器本地密码文件或交互输入提供密码，否则解密失败并终止安装。
