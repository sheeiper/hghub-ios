# 非官方构建镜像 / Unofficial build mirror

本仓库是 [Minireel/HGhub](https://github.com/Minireel/HGhub) **v1.2.0** 的源码快照，用途只有一个：
在 GitHub Actions 的 macOS runner 上编译出**未签名**的 iOS 安装包（IPA），供仓库所有者本人用
SideStore / AltStore / Sideloadly 以自己的 Apple ID 重签后，侧载到自己的设备上。

- 未修改任何业务代码；只新增了 `.github/workflows/ios-unsigned.yml` 与 `scripts/ios-unsigned-ipa.sh`。
- 不提供、不存储、不分发任何音视频内容；所有内容均来自上游第三方站点。
- 产物是**未签名** IPA：不能直接安装，必须自行重签；免费 Apple ID 的签名 7 天后失效。
- 许可证：[PolyForm Noncommercial 1.0.0](./LICENSE)，**仅限非商业用途**。
  Required Notice: `Copyright (c) 2026 HGhub contributors (https://github.com/Minireel/HGhub)`
- 官方渠道只有上游仓库与其 Releases：<https://github.com/Minireel/HGhub/releases>。
  本项目与上游作者无隶属关系，任何问题请勿向上游反馈。

## 构建

仓库自带一条 `workflow_dispatch` 流水线：

1. Actions → **iOS unsigned IPA** → Run workflow；
2. 结束后在该次运行的 Artifacts 里下载 `HGhub-unsigned-ipa`；
3. 用侧载工具重签安装。

产物结构：`Payload/HGhub.app`，arm64，最低 iOS 15.0。
