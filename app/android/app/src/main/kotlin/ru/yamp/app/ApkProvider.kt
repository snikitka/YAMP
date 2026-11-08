package ru.yamp.app

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

class ApkProvider : ContentProvider() {
    companion object {
        private const val AUTHORITY = "ru.yamp.app.apk"
        private const val MIME = "application/vnd.android.package-archive"

        fun install(context: Context, path: String) {
            val name = File(path).name
            val uri = Uri.Builder().scheme("content").authority(AUTHORITY).appendPath(name).build()
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, MIME)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            runCatching { context.startActivity(intent) }
        }
    }

    private fun file(uri: Uri): File {
        val dir = File(requireNotNull(context).cacheDir, "update").canonicalFile
        val name = uri.lastPathSegment ?: throw FileNotFoundException()
        val f = File(dir, name).canonicalFile
        if (f.parentFile != dir || !f.isFile) throw FileNotFoundException(name)
        return f
    }

    override fun onCreate() = true

    override fun getType(uri: Uri) = MIME

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor =
        ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY)

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val f = file(uri)
        val cols = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(cols, 1).apply { addRow(arrayOf<Any>(f.name, f.length())) }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
}
