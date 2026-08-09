# 发布：签名与公证

这份文档解决一个具体问题：**别人下载了 KeysMirror，双击打不开。**

## 现在是什么状况

发布流程（`.github/workflows/release.yml`）能走两条路：

| | ad-hoc 签名（当前默认） | Developer ID + 公证 |
|---|---|---|
| 需要付费开发者账号 | 不需要 | 需要（$99/年） |
| 用户首次打开 | 会被 Gatekeeper 拦住，要右键 →「打开」，再去系统设置点「仍要打开」 | 双击直接开 |
| 用户会看到的提示 | 「无法验证开发者，可能包含恶意软件」 | 无 |
| 配置成本 | 零 | 一次性配 6 个 secrets |

CI 会自己判断：**secrets 配齐了就走正式签名 + 公证，没配就退回 ad-hoc**，不会因为缺配置而发不出版本。所以你可以先不管这份文档，等确实需要给别人用了再回来配。

## 要配的 6 个 secrets

在 GitHub 仓库 → Settings → Secrets and variables → Actions 里添加：

| 名字 | 是什么 | 怎么拿 |
|---|---|---|
| `MACOS_CERTIFICATE` | Developer ID Application 证书的 base64 | 见下面「导出证书」 |
| `MACOS_CERTIFICATE_PWD` | 导出证书时你设的密码 | 自己定的 |
| `MACOS_SIGNING_IDENTITY` | `Developer ID Application: 你的名字 (TEAMID)` | 终端跑 `security find-identity -v -p codesigning` 复制整个引号内的字符串 |
| `APPLE_ID` | 开发者账号邮箱 | 你自己的 |
| `APPLE_APP_PASSWORD` | App 专用密码 | [appleid.apple.com](https://appleid.apple.com) → 登录与安全 → App 专用密码 → 生成一个。**不是**你的登录密码 |
| `APPLE_TEAM_ID` | 10 位团队 ID | [developer.apple.com/account](https://developer.apple.com/account) 右上角，或 `security find-identity` 输出里括号中那串 |

### 导出证书

1. 在 [developer.apple.com](https://developer.apple.com/account/resources/certificates) 创建一个 **Developer ID Application** 证书，下载后双击装进钥匙串。
2. 打开「钥匙串访问」→ 登录 → 我的证书 → 找到 `Developer ID Application: ...` → 右键「导出」→ 存成 `.p12`，设一个密码（这个密码就是 `MACOS_CERTIFICATE_PWD`）。
3. 转成 base64：

```bash
base64 -i ~/Desktop/KeysMirror.p12 | pbcopy
```

粘贴到 `MACOS_CERTIFICATE`。

> `.p12` 文件本身别提交进仓库，也别留在桌面。配完 secrets 就删掉。

## 配完之后必须验一遍

打开 Hardened Runtime 之后，**必须真机确认功能没被它挡住**。KeysMirror 作为「辅助功能客户端」使用 AX API 和 CGEventTap，理论上不需要额外的 entitlement，但这件事只有跑一遍才算数：

1. 从 Release 页面下载 zip，解压，拖进「应用程序」；
2. 双击打开——**不应该**出现任何「无法验证开发者」的提示；
3. 去「系统设置 → 隐私与安全性 → 辅助功能」勾选 KeysMirror；
4. 打开一个配好映射的应用，按一次触发键，确认点击生效；
5. 跑一条宏，确认能正常循环和停止。

第 2 步失败 → 公证没成功，去看 Actions 里 `Notarize and staple` 那一步的输出。
第 4 或 5 步失败 → Hardened Runtime 挡住了某个能力，需要在 `KeysMirror/KeysMirror.entitlements` 里补对应 entitlement 后重发一版。

## 还没做的事

- **DMG 打包**：现在发的是 zip。DMG 体验更好（带拖进 Applications 的背景图），但要额外做背景图和 `create-dmg` 流程，暂时没做。
- **自动更新**：没有 Sparkle 之类的更新框架，用户只能自己去 Release 页面下新版。
