# 平台 logo 资源（原生版 LiziNative 随包）

来源：壳版 `public/assets/platforms/*.svg`（iconfont 路径数据），用 cairosvg
渲染成 48/96/144 三档 PNG 进 imageset（Xcode 15+ 的 Asset Catalog 虽然
支持 SVG 矢量，但构建机 Xcode 版本与 SVG 特性兼容性未经实测；三档 PNG
是能进包且真机一定显示正常的办法；P1 的品牌色 + 首字瓷砖已撤下，
只在资源缺失时作兜底）。

渲染命令（VM 上实测通过）：

```sh
python3 -c "
import cairosvg
cairosvg.svg2png(url='public/assets/platforms/netease.svg',
                 write_to='.../PlatformNetease.imageset/PlatformNetease@3x.png',
                 output_width=144, output_height=144)"
```

映射（7 家，顺序与 `LiziPlatforms.all` 一致）：

| 资源 | SVG 源 |
| --- | --- |
| PlatformNetease | netease.svg |
| PlatformQQ | qq.svg |
| PlatformKugou | kugou.svg（自含蓝底，勿用 kugou-mark.svg——它是纯白镂空，白底看不见） |
| PlatformQishui | qishui.svg |
| PlatformBodian | bodian.svg |
| PlatformKuwo | kuwo.svg |
| PlatformAppleMusic | applemusic.svg |

像素抽查（VM 上 PIL 实测）：酷狗 144 图蓝像素 14,357/20,736（69%，
中间透明带是白 K 字的镂空，显示时透出底色，与网页版一致）；网易红
16,410、QQ 黄 9,990；7 张不透明占比 70–98%，无空白图。
