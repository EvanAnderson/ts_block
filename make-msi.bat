@echo off
del *.msi
del *.wixobj
candle -out ts_block.wixobj ts_block.wxs
light -out ts_block.MSI ts_block.wixobj
