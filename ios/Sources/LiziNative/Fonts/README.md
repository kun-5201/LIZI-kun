# Fraunces 字体（原生版 LiziNative 随包字体）

来源：google/fonts 仓库的完整 OFL 可变字体（不是壳版 `public/m/fonts/` 里的
woff2 子集——那四个子集是互补切分：latin 只有 ASCII/拉丁基础，latin-ext
只有扩展字符，单用任何一个都会缺字；合并子集不如直接用完整字体干净）。

- `Fraunces[SOFT,WONK,opsz,wght].ttf`
  https://github.com/google/fonts/blob/main/ofl/fraunces/Fraunces%5BSOFT%2CWONK%2Copsz%2Cwght%5D.ttf
- `Fraunces-Italic[SOFT,WONK,opsz,wght].ttf`
  https://github.com/google/fonts/blob/main/ofl/fraunces/Fraunces-Italic%5BSOFT%2CWONK%2Copsz%2Cwght%5D.ttf
- 许可证：SIL Open Font License 1.1（见同目录 `OFL.txt`）。

iOS 不能直接用 woff2，且可变字体的默认字重是 900（直接打包会全是 Black），
所以用 fontTools 实例化成三档静态 TTF（与壳版 `public/m/fonts.css` 的请求
一致：正体 500/600、斜体 500；opsz 固定 144，走展示端；SOFT=0、WONK=1
与网页版一致；中文不在字体内，由系统字体兜底）：

```sh
python3 -m fontTools.varLib.instancer "Fraunces[SOFT,WONK,opsz,wght].ttf" \
  wght=500 opsz=144 SOFT=0 WONK=1 -o Fraunces-Medium.ttf
python3 -m fontTools.varLib.instancer "Fraunces[SOFT,WONK,opsz,wght].ttf" \
  wght=600 opsz=144 SOFT=0 WONK=1 -o Fraunces-SemiBold.ttf
python3 -m fontTools.varLib.instancer "Fraunces-Italic[SOFT,WONK,opsz,wght].ttf" \
  wght=500 opsz=144 SOFT=0 WONK=1 -o Fraunces-Italic.ttf
```

注意：`--update-name-table` 会因 STAT 表没有 wght 500 的命名值而报错
（`Cannot find Axis Values {'wght': 500.0}`），所以实例化时不加它，
事后用 fontTools 把名字表改成 `Fraunces / Medium|SemiBold|Italic /
Fraunces-Medium|…`（族名保持 `Fraunces`，`Font.custom("Fraunces")`
才能按字重/斜体匹配到三档）。

注册：`ios/project.yml` 里 LiziNative target 的 `info.properties`
`UIAppFonts` 列出这三个文件名（不要手写 Info.plist 文件），
`resources` 列出三个文件进包；使用处是 `Views/Home/DesignTokens.swift`
的 `Font.liziDisplay`（`Font.custom("Fraunces", size:)` + weight 透传，
字体缺失时回落系统 serif）。
