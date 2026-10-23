package com.vortx.android.imports

// Only the browser UA collaborator is synthetic; ImportHttp and its transport compile from source.
// Kept outside Android source sets so this cannot replace the production ListImport object.
internal object ListImport { const val BROWSER_UA = "VortX-Android-Fixture/1.0" }
