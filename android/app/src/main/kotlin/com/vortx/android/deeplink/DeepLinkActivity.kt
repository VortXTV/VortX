package com.vortx.android.deeplink

import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import androidx.activity.ComponentActivity
import com.vortx.android.MainActivity
import com.vortx.android.ui.tv.TvActivity

/** Routes an accepted lowercase custom-scheme URL to the correct form-factor launcher. */
class DeepLinkActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (VortXDeepLinks.parse(intent?.dataString) == null) {
            finish()
            return
        }

        val mode = resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK
        val target = if (mode == Configuration.UI_MODE_TYPE_TELEVISION) TvActivity::class.java else MainActivity::class.java
        startActivity(
            Intent(this, target)
                .setData(intent.data)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        )
        finish()
    }
}
