package com.example.omsg_app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val deepLinkChannel = "omsg/deep_links"
    private val deepLinkEventsChannel = "omsg/deep_links/events"

    private var latestLink: String? = null
    private var eventsSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        latestLink = intent?.dataString

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deepLinkChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialLink" -> result.success(latestLink)
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, deepLinkEventsChannel)
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                        eventsSink = events
                    }

                    override fun onCancel(arguments: Any?) {
                        eventsSink = null
                    }
                }
            )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        latestLink = intent.dataString
        latestLink?.let { eventsSink?.success(it) }
    }
}
