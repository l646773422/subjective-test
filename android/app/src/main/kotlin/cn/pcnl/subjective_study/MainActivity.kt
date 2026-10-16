package cn.pcnl.subjective_study

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private val requestTree = 7301

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cn.pcnl.study/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "appDirectory" -> result.success(filesDir.absolutePath)
                    "presentation" -> {
                        if (call.arguments == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    "pickDirectory" -> {
                        if (pending != null) {
                            result.error("BUSY", "已有目录选择请求", null)
                        } else {
                            pending = result
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                            try { startActivityForResult(intent, requestTree) }
                            catch (e: Exception) {
                                pending = null
                                result.error("PICK", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
    data class Entry(val id: String, val name: String, val directory: Boolean)
    private fun children(tree: Uri, parent: String): List<Entry> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent)
        val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE)
        val items = mutableListOf<Entry>()
        contentResolver.query(uri, columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val name = cursor.getString(1)
                require(name != "." && name != ".." && !name.contains("/") &&
                    !name.contains("\\")) { "不安全的文件名" }
                items.add(Entry(cursor.getString(0), name,
                    cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR))
            }
        }
        return items
    }
    @Deprecated("Uses Activity result forwarding supported by FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != requestTree) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val callback = pending ?: return
        pending = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            callback.success(null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: SecurityException) { /* Snapshot import does not need later URI access. */ }
        Thread {
            val destination = File(filesDir, "imports/" + System.nanoTime())
            try {
                destination.mkdirs()
                var total = 0L
                fun copy(parent: String, target: File, depth: Int, directoryName: String) {
                    require(depth <= 8) { "目录层级过深" }
                    var entries = children(tree, parent)
                    if (directoryName == "test") {
                        entries = entries.filter { it.directory &&
                            it.name.matches(Regex("ours_[0-9]+")) }
                            .maxByOrNull { it.name.substring(5).toLongOrNull() ?: -1 }
                            ?.let { listOf(it) } ?: emptyList()
                    }
                    for (entry in entries) {
                        val output = File(target, entry.name)
                        if (entry.directory) {
                            if (entry.name.matches(Regex("frame[0-9]+")) ||
                                entry.name.matches(Regex("ours_[0-9]+")) ||
                                entry.name in listOf("test", "gt", "renders")) {
                                output.mkdirs()
                                copy(entry.id, output, depth + 1, entry.name)
                            }
                        } else if (entry.name.lowercase().endsWith(".png") ||
                            entry.name.lowercase().endsWith(".jpg") ||
                            entry.name.lowercase().endsWith(".jpeg") ||
                            entry.name in listOf("view_ids.json", "DEMO_ONLY.txt")) {
                            val uri = DocumentsContract.buildDocumentUriUsingTree(tree, entry.id)
                            contentResolver.openInputStream(uri)?.use { input ->
                                output.outputStream().use { out ->
                                    val buffer = ByteArray(65536)
                                    while (true) {
                                        val count = input.read(buffer)
                                        if (count < 0) break
                                        total += count
                                        require(total <= 1024L * 1024L * 1024L) {
                                            "图片目录超过 1 GB，请先在 PC 导出精简测试包"
                                        }
                                        out.write(buffer, 0, count)
                                    }
                                }
                            } ?: error("无法读取选定图片")
                        }
                    }
                }
                copy(DocumentsContract.getTreeDocumentId(tree), destination, 0, "")
                runOnUiThread { callback.success(destination.absolutePath) }
            } catch (e: Exception) {
                // This exact directory is owned by this failed import.
                destination.deleteRecursively()
                runOnUiThread { callback.error("IMPORT", e.message, null) }
            }
        }.start()
    }
}
