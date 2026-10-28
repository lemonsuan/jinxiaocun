package com.xcy.yuntuitui.inventory.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureModePolicyTest {
    @Test fun `低内存或不支持ZSL时保留低延迟模式`() {
        assertTrue(CaptureModePolicy.preferZeroShutterLag(true, false))
        assertFalse(CaptureModePolicy.preferZeroShutterLag(true, true))
        assertFalse(CaptureModePolicy.preferZeroShutterLag(false, false))
        assertFalse(CaptureModePolicy.preferZeroShutterLag(false, true))
    }

    @Test fun `支持的绑定成功不额外重建相机`() {
        val modes = mutableListOf<Boolean>()
        var cleanups = 0
        val result = CaptureModePolicy.bindWithFallback(true, {
            modes.add(it)
            "bound"
        }, { cleanups++ })
        assertEquals("bound", result)
        assertEquals(listOf(true), modes)
        assertEquals(0, cleanups)
    }

    @Test fun `三流不兼容先清资源再单次回退`() {
        val events = mutableListOf<String>()
        CaptureModePolicy.bindWithFallback(true, { zsl ->
            events.add("bind:$zsl")
            if (zsl) throw IllegalArgumentException("unsupported streams")
            "bound"
        }, { events.add("cleanup") })
        assertEquals(listOf("bind:true", "cleanup", "bind:false"), events)
    }

    @Test fun `回退仍失败直接抛出不无限重试`() {
        val modes = mutableListOf<Boolean>()
        assertThrows(IllegalStateException::class.java) {
            CaptureModePolicy.bindWithFallback(true, { zsl ->
                modes.add(zsl)
                throw IllegalStateException("camera failed")
            }, {})
        }
        assertEquals(listOf(true, false), modes)
    }

    @Test fun `普通低延迟绑定失败不尝试额外模式`() {
        val modes = mutableListOf<Boolean>()
        assertThrows(IllegalStateException::class.java) {
            CaptureModePolicy.bindWithFallback(false, { zsl ->
                modes.add(zsl)
                throw IllegalStateException("camera failed")
            }, { throw AssertionError("不应回退") })
        }
        assertEquals(listOf(false), modes)
    }
}
