package com.vortx.android.ui.components

import android.graphics.Bitmap
import android.graphics.Color
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter

/// Render [value] as a black-on-white QR [Bitmap], or null if encoding fails (empty/too-long value). Shared
/// by the add-on pairing QR, the Configure-on-TV QR, and any other QR affordance so the zxing call lives in
/// one place (the account QR predates this and keeps its own copy).
fun qrBitmap(value: String, size: Int = 512): Bitmap? = runCatching {
    val matrix = QRCodeWriter().encode(value, BarcodeFormat.QR_CODE, size, size)
    val pixels = IntArray(matrix.width * matrix.height)
    for (y in 0 until matrix.height) {
        for (x in 0 until matrix.width) {
            pixels[y * matrix.width + x] = if (matrix[x, y]) Color.BLACK else Color.WHITE
        }
    }
    Bitmap.createBitmap(pixels, matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
}.getOrNull()
