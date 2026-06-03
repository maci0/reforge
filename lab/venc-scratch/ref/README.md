# Reference: Allwinner cedarx encoder register map

`cedarx_video_enc_reg.h` — the H264 encoder register definitions from Allwinner's open
cedarx framework (`allwinner-zh/media-codec/sunxi-cedarx/SOURCE/vencoder/include/`, LGPL-2.1).
Offsets are relative to the **encoder bank = VE base + 0xB00** (ISP bank = base + 0xA00),
confirmed by that repo's `EncAdapter.c`. Used to interpret the T113 VE encoder during the
from-scratch bring-up (see ../README.md). The actual encode loop lives in the closed
`libcedar_plugin_venc` blob and is NOT in the open framework.
