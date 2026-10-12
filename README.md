# Legu(乐读)

书源式 iOS 小说阅读器 —— 参考 [阅读(Legado)](https://gedoor.github.io/) 的功能设计:

- **书源引擎**:完整实现 Legado 书源规则(默认链式 / XPath 子集 / CSS 子集 / `##` 后处理 / `@js:` / `@get:` / `@put:`),
  可直接导入 Legado 格式的 JSON 书源合集
- **多源聚合搜索**:所有启用书源并发搜索,结果流式返回
- **在线阅读**:目录 + 逐章正文,自动记录阅读进度
- **离线下载**:整本下载到本机(断点续传 / 暂停继续 / 批量删除),下载的书离线可读可听
- **Z-Library 电子书**:登录后搜索下载 EPUB,整本解析进书架,离线阅读 / 听书
- **听书(TTS)**:系统语音 / 微软音色 / 自定义引擎(支持自建声线服务),后台播放 + 锁屏控制,**听读同步(高亮当前句 + 自动跟页)**
- **缓存管理**:听书音频 / 封面与网页 / 阅读内存缓存一键清理
- **书内排版**:字号 / 行距 / 段距 / 四套主题,设置持久化
- **内置原生书源**:七猫免费小说、番茄小说、202小说网、非凡中文、新笔趣阁、飘天文学、笔趣阁365、和图书、耽美小说、52书库

## 一键导入(书源页 → +)

| 合集 | 来源 |
|---|---|
| xiu2 合集 | `https://raw.ixnic.net/XIU2/Yuedu/master/shuyuan`(及 bitbucket 镜像) |
| yiove:25 个优质书源 | yiove 书源仓库 |
| yiove:稳定书源合集 | yiove 书源仓库 |
| yiove:已效验 383 个 | yiove 书源仓库 |
| yiove:星辰整理合集 | yiove 书源仓库 |

也支持任意书源 JSON 链接或粘贴导入。

## 构建

```bash
brew install xcodegen
xcodegen generate
open Legu.xcodeproj
```

CI(GitHub Actions)会自动构建测试并产出未签名 IPA(`legu-unsigned-ipa` artifact)。

## 安装

未签名 IPA 见 [Releases](https://github.com/MyHeart133/legu/releases)(`Legu-unsigned.ipa`),
用 Sideloadly / AltStore 等自签工具安装(iOS 17+)。

## 结构

```
Legu/
  Engine/   书源引擎(HTML 解析器 / 规则求值 / JS / XPath / CSS / Legado 模型)
  Sources/  内容源协议 + 原生书源(七猫 / 番茄 / 聚合镜像…)
  Store/    书源仓库 / 书架 / 聚合搜索
  Net/      网络层(编码识别) + 文本工具
  UI/       书架 / 搜索 / 书源管理 / 详情 / 阅读器 / 设置
```
