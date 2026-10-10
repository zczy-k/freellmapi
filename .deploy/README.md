# FreeLLMAPI 部署配置

## 文件说明
- `freellmapi-deploy` — 服务器部署脚本(CI 会自动上传并执行)
- README.md — 本文档

## 用法
```bash
# 查看当前部署状态
/root/freellmapi-deploy --status

# 手动触发一次部署(需先上传产物包)
/root/freellmapi-deploy --artifact <code.tar.gz> --deps <deps.tar.gz> --sha <commit>
