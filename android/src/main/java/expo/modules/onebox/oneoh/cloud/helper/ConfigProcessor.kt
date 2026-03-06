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
                if (cacheFile.has("path")) {
                    val cachePath = "$workingDir/cache/tun.db"
                    cacheFile.put("path", cachePath)

                    val cacheDirectory = File("$workingDir/cache")
                    if (!cacheDirectory.exists()) {
                        cacheDirectory.mkdirs()
                    }
                }
            }
        }
        json.toString()
    } catch (e: Exception) {
        Log.w(TAG, "Failed to process config", e)
        config
    }
}

/**
 * 从配置中移除 TUN 类型的 inbound（保留 mixed 等其他 inbound）。
 * 目前仅做 JSON 转换，预留后续扩展点。
 */
internal fun removeTunInbound(config: String): String {
    return try {
        val json = JSONObject(config)
        json.toString()
    } catch (e: Exception) {
        Log.w(TAG, "Failed to remove TUN inbound", e)
        config
    }
}
