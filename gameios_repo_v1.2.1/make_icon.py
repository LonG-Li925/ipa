# -*- coding: utf-8 -*-
"""生成 iOS 1024x1024 AppIcon（必须无 alpha 通道，App Store 会拒收带透明的图）"""
import os
from PIL import Image, ImageFilter

SRC = r"D:\下载\20261026-224459.png"
OUT = r"E:\android_build\GameIOS\Resources\Assets.xcassets\AppIcon.appiconset\icon-1024.png"

img = Image.open(SRC).convert("RGBA")
# 铺黑底，去掉透明
bg = Image.new("RGB", img.size, (0, 0, 0))
bg.paste(img, mask=img.split()[3])
img = bg

# 放大到 1024 再轻微锐化，避免糊
big = img.resize((1024, 1024), Image.LANCZOS)
big = big.filter(ImageFilter.UnsharpMask(radius=1.4, percent=110, threshold=2))
big.save(OUT, "PNG", optimize=True)
print("saved", OUT, os.path.getsize(OUT), "bytes", big.mode, big.size)
