package com.leadaxe.lxbox.vpn

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// §747 — чистка после падения ядра трогает только временный каталог ядра:
/// соседи в `cacheDir` (временные файлы Flutter и плагинов, посылки вызовов
/// `bg-xfer`) остаются.
class CrashRecoveryTempTest {

    @Test
    fun `only the core temp dir is cleared`() {
        val cache = Files.createTempDirectory("lxbox-cache").toFile()
        try {
            val core = File(cache, "core-tmp").apply { mkdirs() }
            File(core, "a.tmp").writeText("x")
            File(core, "sub").mkdirs()
            File(core, "sub/b.tmp").writeText("y")
            val xfer = File(cache, BgCodec.XFER_DIR).apply { mkdirs() }
            val parcel = File(xfer, "x-1.bin").apply { writeText("args") }
            val flutter = File(cache, "flutter_tmp.png").apply { writeText("img") }

            assertEquals(2 to 2, CrashRecovery.deleteContents(core))

            assertTrue(core.isDirectory)
            assertEquals(0, core.listFiles()!!.size)
            assertTrue(parcel.isFile)
            assertTrue(flutter.isFile)
        } finally {
            cache.deleteRecursively()
        }
    }

    @Test
    fun `a missing temp dir is not an error`() {
        val gone = File(System.getProperty("java.io.tmpdir"), "lxbox-no-such-dir-${System.nanoTime()}")
        assertFalse(gone.exists())
        assertEquals(null, CrashRecovery.deleteContents(gone))
        assertFalse(gone.exists())
    }
}
