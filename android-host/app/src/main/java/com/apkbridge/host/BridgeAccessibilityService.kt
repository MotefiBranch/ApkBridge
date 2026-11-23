package com.apkbridge.host

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class BridgeAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: BridgeAccessibilityService? = null
            private set
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var lastX = 0f
    private var lastY = 0f
    private var activeStroke: GestureDescription.StrokeDescription? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // No-op: only using gesture dispatch and node input
    }

    override fun onInterrupt() {
        activeStroke = null
    }

    fun onTouchDown(x: Float, y: Float) {
        mainHandler.post {
            lastX = x
            lastY = y
            val path = Path().apply { moveTo(x, y) }
            val stroke = GestureDescription.StrokeDescription(path, 0L, 40L, true)
            activeStroke = stroke
            dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
        }
    }

    fun onTouchMove(x: Float, y: Float) {
        mainHandler.post {
            val prev = activeStroke ?: return@post
            val dx = x - lastX
            val dy = y - lastY
            if (dx * dx + dy * dy < 4f) return@post

            val path = Path().apply {
                moveTo(lastX, lastY)
                lineTo(x, y)
            }
            lastX = x
            lastY = y
            val next = prev.continueStroke(path, 0L, 32L, true)
            activeStroke = next
            dispatchGesture(GestureDescription.Builder().addStroke(next).build(), null, null)
        }
    }

    fun onTouchUp(x: Float, y: Float) {
        mainHandler.post {
            val prev = activeStroke
            activeStroke = null
            if (prev != null) {
                val path = Path().apply {
                    moveTo(lastX, lastY)
                    lineTo(x, y)
                }
                val endStroke = prev.continueStroke(path, 0L, 20L, false)
                dispatchGesture(GestureDescription.Builder().addStroke(endStroke).build(), null, null)
            } else {
                val path = Path().apply { moveTo(x, y) }
                val tap = GestureDescription.StrokeDescription(path, 0L, 35L, false)
                dispatchGesture(GestureDescription.Builder().addStroke(tap).build(), null, null)
            }
        }
    }

    fun performNav(action: String) {
        mainHandler.post {
            when (action) {
                "back" -> performGlobalAction(GLOBAL_ACTION_BACK)
                "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
                "recents" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            }
        }
    }

    fun injectText(text: String) {
        mainHandler.post {
            val root = rootInActiveWindow ?: return@post
            val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return@post
            val existing = focused.text?.toString() ?: ""
            val args = Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    existing + text
                )
            }
            focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        }
    }

    fun backspaceText() {
        mainHandler.post {
            val root = rootInActiveWindow ?: return@post
            val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return@post
            val existing = focused.text?.toString() ?: ""
            if (existing.isNotEmpty()) {
                val args = Bundle().apply {
                    putCharSequence(
                        AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                        existing.dropLast(1)
                    )
                }
                focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            }
        }
    }
}
