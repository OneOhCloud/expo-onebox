package expo.modules.onebox.oneoh.cloud.helper

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File

private const val TAG = "ConfigProcessor"

/**
 * 返回 VPN 工作目录：优先外部存储，回退到内部 filesDir。
 */
internal fun getWorkingDir(context: Context): File {
    return context.getExternalFilesDir(null) ?: context.filesDir
}

/**
 * 处理配置：将 experimental.cache_file.path 替换为 Android 应用目录下的绝对路径，
 * 并自动创建缓存目录。
 */
internal fun processConfig(config: String, context: Context): String {
    return try {
        val json = JSONObject(config)
        val workingDir = getWorkingDir(context).absolutePath

        if (json.has("experimental")) {
            val experimental = json.getJSONObject("experimental")
            if (experimental.has("cache_file")) {
                val cacheFile = experimental.getJSONObject("cache_file")
                val cachePath = "$workingDir/tun.db"
                cacheFile.put("path", cachePath)
                cacheFile.put("enabled", true)
                Log.i(TAG, "workingDir: $workingDir")
                Log.i(TAG, "config[experimental] cachePath: $cachePath")
            }
        }
        // Do NOT log the processed config — it contains user profile data
        // (server hostnames, passwords/UUIDs). See config-fetch-policy.md
        // log-redaction contract.
        json.toString()
    } catch (e: Exception) {
        Log.w(TAG, "Failed to process config", e)
        config
    }
}

