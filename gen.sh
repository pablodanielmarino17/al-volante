#!/usr/bin/env bash
# Genera el proyecto Android "Al volante" en ./proj
set -e
rm -rf proj
mkdir -p proj
cat > 'proj/build.gradle.kts' <<'EOF_ALVOLANTE'
plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
EOF_ALVOLANTE
cat > 'proj/gradle.properties' <<'EOF_ALVOLANTE'
org.gradle.jvmargs=-Xmx3g
android.useAndroidX=true
kotlin.code.style=official
EOF_ALVOLANTE
cat > 'proj/settings.gradle.kts' <<'EOF_ALVOLANTE'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "AlVolante"
include(":app")
EOF_ALVOLANTE
mkdir -p "proj/app"
cat > 'proj/app/build.gradle.kts' <<'EOF_ALVOLANTE'
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "com.pablo.alvolante"
    compileSdk = 34
    defaultConfig {
        applicationId = "com.pablo.alvolante"
        minSdk = 29
        targetSdk = 34
        versionCode = 6
        versionName = "1.5"
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
    }
    signingConfigs {
        create("fija") {
            storeFile = file("../../keystore/debug.jks")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }
    buildTypes { getByName("debug") { signingConfig = signingConfigs.getByName("fija") } }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
dependencies {
    implementation("com.google.mlkit:text-recognition:16.0.1")
}
EOF_ALVOLANTE
mkdir -p "proj/app/src/main"
cat > 'proj/app/src/main/AndroidManifest.xml' <<'EOF_ALVOLANTE'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />
    <application
        android:label="Al volante"
        android:icon="@drawable/ic_launcher"
        android:allowBackup="true"
        android:theme="@android:style/Theme.DeviceDefault.DayNight">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
        <service
            android:name=".DidiReaderService"
            android:exported="true"
            android:label="@string/a11y_label"
            android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
            <intent-filter>
                <action android:name="android.accessibilityservice.AccessibilityService" />
            </intent-filter>
            <meta-data android:name="android.accessibilityservice" android:resource="@xml/accessibility_config" />
        </service>
    </application>
</manifest>
EOF_ALVOLANTE
mkdir -p "proj/app/src/main/java/com/pablo/alvolante"
cat > 'proj/app/src/main/java/com/pablo/alvolante/DidiReaderService.kt' <<'EOF_ALVOLANTE'
package com.pablo.alvolante

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.LinearLayout
import android.widget.TextView
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions

/** Lee la pantalla de DiDi (solo lectura) y muestra el semáforo. Nunca toca ni acepta nada. */
class DidiReaderService : AccessibilityService() {
    companion object {
        @Volatile var instance: DidiReaderService? = null
        @Volatile var lastLines: List<String> = emptyList()
        val seenPkgs = LinkedHashSet<String>()
        // textos de DiDi que aparecen cuando ya tomaste el viaje
        val VIAJE = listOf("iniciar viaje", "finalizar viaje", "terminar viaje", "comenzar viaje", "llegué", "ya llegué",
            "pasajero a bordo", "ir a buscar", "recoger al pasajero", "en camino al punto", "deslizá para", "desliza para")
    }

    private val h = Handler(Looper.getMainLooper())
    private var overlay: Overlay? = null
    private var scheduled = false
    private var lastSeenReq = 0L
    private var currentSig: String? = null
    private var currentTs = 0L
    private var currentPedido: Pedido? = null
    private var currentRiesgo: Riesgo? = null
    private var pendingTs = 0L
    private var lastOcr = 0L
    private var ocrBusy = false
    private var urgent = false
    private var lastDidiEvent = 0L

    private val scanR = Runnable { scheduled = false; scan() }
    private val tick = object : Runnable {
        override fun run() {
            if (currentSig != null) {
                if (System.currentTimeMillis() - lastSeenReq > 1200) scan()
                if (currentSig != null && System.currentTimeMillis() - lastSeenReq > 4500) {
                    overlay?.hide()
                    currentSig = null
                }
            }
            h.postDelayed(this, 800)
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        overlay = Overlay(this)
        instance = this
        Zonas.cargar(this)
        h.post(tick)
    }

    override fun onDestroy() {
        instance = null
        overlay?.hide()
        Store.flushOnline(this)
        h.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun onInterrupt() {}

    private fun isDidi(p: String): Boolean {
        val l = p.lowercase()
        return l.contains("didi") || l.contains("xiaojukeji")
    }

    override fun onAccessibilityEvent(e: AccessibilityEvent?) {
        if (e == null) return
        val pkg = e.packageName?.toString() ?: return
        if (pkg == packageName) return
        synchronized(seenPkgs) { if (seenPkgs.size < 40) seenPkgs.add(pkg) }
        if (!isDidi(pkg)) return
        lastDidiEvent = System.currentTimeMillis()
        // una ventana nueva de DiDi (por ejemplo, la tarjeta de un pedido) se lee enseguida
        if (e.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED || e.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED) urgent = true
        if (!scheduled) {
            scheduled = true
            h.postDelayed(scanR, if (urgent) 150L else 300L)
        }
    }

    private fun collect(n: AccessibilityNodeInfo?, out: ArrayList<String>, depth: Int) {
        if (n == null || depth > 50 || out.size > 900) return
        val tx = n.text?.toString()
        if (tx != null) for (t in tx.split('\n')) { val s = t.trim(); if (s.isNotEmpty()) out.add(s) }
        val cd = n.contentDescription?.toString()
        if (cd != null && cd != tx) for (t in cd.split('\n')) { val s = t.trim(); if (s.isNotEmpty()) out.add(s) }
        for (i in 0 until n.childCount) collect(n.getChild(i), out, depth + 1)
    }

    fun scan() {
        val lines = ArrayList<String>()
        var visible = false
        try {
            for (w in windows) {
                val r = w.root ?: continue
                if (isDidi(r.packageName?.toString() ?: "")) { visible = true; collect(r, lines, 0) }
            }
        } catch (e: Exception) { }
        if (!visible) {
            try {
                val r = rootInActiveWindow
                if (r != null && isDidi(r.packageName?.toString() ?: "")) { visible = true; collect(r, lines, 0) }
            } catch (e: Exception) { }
        }
        if (!visible) return
        val now = System.currentTimeMillis()
        if (lines.isNotEmpty()) lastLines = lines
        if (Store.getB(this, "aprender", false)) Store.learnLines(this, lines)
        revisarEstado(lines, now)

        val p = Parser.parse(lines)
        if (lines.any { Parser.minRx.containsMatchIn(it) }) Store.saveSnap(this, lines, p != null)
        if (p != null) { handlePedido(p, now); return }
        maybeOcr()
    }

    /** Conectado ("Buscando") o en viaje: suma tiempo conectado y detecta si tomaste el último pedido. */
    private fun revisarEstado(lines: List<String>, now: Long) {
        val low = lines.joinToString(" ").lowercase()
        val enViaje = VIAJE.any { low.contains(it) }
        if (enViaje || low.contains("buscando")) Store.marcarConectado(this, now)
        if (enViaje && pendingTs > 0 && now - pendingTs < 300000 && now - lastSeenReq > 1500) {
            Store.setTomado(this, pendingTs, true)
            pendingTs = 0
        }
    }

    private fun handlePedido(p: Pedido, now: Long) {
        lastSeenReq = now
        val sig = p.price.toString() + "|" + p.tKm + "|" + p.pKm
        if (sig == currentSig) return
        currentSig = sig
        currentPedido = p
        val usarZona = Store.getD(this, "zp", 15.0) > 0
        currentRiesgo = if (usarZona) Riesgo(true, null, null, false, false) else null
        val ev = Evaluator.eval(this, p, currentRiesgo)
        overlay?.show(ev, p)
        val ts = Store.logPedido(this, p, ev)
        currentTs = ts
        pendingTs = ts
        if (usarZona) {
            Zonas.evaluar(this, p) { r ->
                if (currentSig == sig) {
                    currentRiesgo = r
                    val ev2 = Evaluator.eval(this, p, r)
                    overlay?.show(ev2, p)
                    Store.actualizarEval(this, ts, ev2)
                }
            }
        }
    }

    /** Si DiDi no deja leer la tarjeta como texto, saca una foto de la pantalla y la lee. */
    private fun maybeOcr() {
        if (Build.VERSION.SDK_INT < 30) return
        if (!Store.getB(this, "ocr", true)) return
        val now = System.currentTimeMillis()
        // al instante si DiDi abrió una ventana; si no, más espaciado para cuidar la batería
        val gap = if (urgent) 500L else if (currentSig != null || now - lastDidiEvent < 2000) 1500L else 3500L
        if (ocrBusy || now - lastOcr < gap) return
        urgent = false
        ocrBusy = true
        lastOcr = now
        try {
            takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : AccessibilityService.TakeScreenshotCallback {
                override fun onSuccess(r: AccessibilityService.ScreenshotResult) {
                    var bmp: Bitmap? = null
                    try {
                        val hb = r.hardwareBuffer
                        bmp = Bitmap.wrapHardwareBuffer(hb, r.colorSpace)?.copy(Bitmap.Config.ARGB_8888, false)
                        hb.close()
                    } catch (e: Exception) { }
                    val b = bmp
                    if (b == null) { ocrBusy = false; return }
                    // se lee debajo de la burbuja (si está), y a resolución moderada para gastar menos
                    val top = (overlay?.bottomPx() ?: 0).coerceIn(0, b.height / 2)
                    var crop = Bitmap.createBitmap(b, 0, top, b.width, b.height - top)
                    if (crop.width > 1080) {
                        val k = 1080.0 / crop.width
                        crop = Bitmap.createScaledBitmap(crop, 1080, (crop.height * k).toInt(), true)
                    }
                    Ocr.readBitmap(crop) { txt ->
                        ocrBusy = false
                        if (txt != null) onOcrText(txt.split("\n"))
                    }
                }
                override fun onFailure(code: Int) { ocrBusy = false }
            })
        } catch (e: Exception) {
            ocrBusy = false
        }
    }

    private fun onOcrText(raw: List<String>) {
        val own = listOf("por km ·", "min en total", "Destino:", "Combustible del viaje", "Rechazo libre", "Búsqueda lejana", "Zona peligrosa", "Zona: ")
        val lines = raw.map { it.trim() }.filter { l -> l.isNotEmpty() && own.none { l.contains(it) } }
        val now = System.currentTimeMillis()
        revisarEstado(lines, now)
        val p = Parser.parse(lines)
        if (lines.any { Parser.minRx.containsMatchIn(it) }) Store.saveSnap(this, listOf("[leído con foto]") + lines, p != null)
        if (p != null) handlePedido(p, now)
    }

    fun test() {
        val p = Pedido(9900.0, "1,2", 3, 0.316, 29, 8.1, "Balvanera", "Puerto Madero",
            "Tucumán 3231, CABA - Balvanera", "Violeta Parra 1677, CABA - Puerto Madero")
        overlay?.show(Evaluator.eval(this, p, null), p)
        h.postDelayed({ if (currentSig == null) overlay?.hide() }, 8000)
    }
}

class Overlay(private val ctx: Context) {
    private val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private var view: View? = null
    private var y = 0
    private val h = Handler(Looper.getMainLooper())
    private val hideR = Runnable { hide() }

    private fun dp(v: Double): Int = (v * ctx.resources.displayMetrics.density).toInt()

    fun bottomPx(): Int {
        val v = view ?: return 0
        return y + v.height + dp(8.0)
    }

    fun show(e: Eval, p: Pedido) {
        hide()
        val k = if (e.level == 4) 1.2f else 1f
        val box = LinearLayout(ctx)
        box.orientation = LinearLayout.VERTICAL
        box.setPadding(dp(18.0), dp(12.0), dp(18.0), dp(14.0))
        val bg = GradientDrawable()
        bg.setColor(e.color)
        bg.cornerRadius = dp(20.0).toFloat()
        box.background = bg
        box.elevation = dp(8.0).toFloat()

        val top = LinearLayout(ctx)
        top.orientation = LinearLayout.HORIZONTAL
        top.gravity = Gravity.CENTER_VERTICAL
        val t1 = TextView(ctx)
        t1.text = e.label + " · " + Fmt.money(p.price)
        t1.textSize = 20f * k
        t1.typeface = Typeface.DEFAULT_BOLD
        t1.setTextColor(e.textColor)
        top.addView(t1, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        val t2 = TextView(ctx)
        t2.text = Fmt.pct(e.pct)
        t2.textSize = 34f * k
        t2.typeface = Typeface.DEFAULT_BOLD
        t2.setTextColor(e.textColor)
        t2.setPadding(dp(14.0), 0, 0, 0)
        top.addView(t2)
        box.addView(top)

        fun line(t: String, size: Float, bold: Boolean) {
            if (t.isEmpty()) return
            val tv = TextView(ctx)
            tv.text = t
            tv.textSize = size * k
            tv.setTextColor(e.textColor)
            if (bold) tv.typeface = Typeface.DEFAULT_BOLD
            box.addView(tv)
        }
        line(Fmt.money(e.perKm) + " por km · " + Fmt.money(e.perHour) + " por hora", 17f, true)
        line(Fmt.num(p.pKm + p.tKm, 1) + " km y " + (p.pMin + p.tMin) + " min en total (" + p.pMin + " min para buscarlo)", 14f, false)
        line(e.zona, 14f, false)
        line(e.riesgo, 14f, true)
        line(e.extras, 14f, true)
        val f = e.fuel
        if (f != null) line("Combustible del viaje: " + Fmt.money(f) + " · te quedan " + Fmt.money(p.price - f), 14f, false)

        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        )
        lp.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
        y = dp(Store.getD(ctx, "overlay_y", 70.0))
        lp.y = y
        lp.horizontalMargin = 0.03f
        try { wm.addView(box, lp); view = box } catch (ex: Exception) { }
        h.removeCallbacks(hideR)
        h.postDelayed(hideR, 40000)
    }

    fun hide() {
        val v = view ?: return
        try { wm.removeView(v) } catch (ex: Exception) { }
        view = null
    }
}

object Ocr {
    private val client by lazy { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS) }

    fun read(c: Context, uri: Uri, cb: (String?) -> Unit) {
        try {
            val img = InputImage.fromFilePath(c, uri)
            client.process(img)
                .addOnSuccessListener { cb(it.text) }
                .addOnFailureListener { cb(null) }
        } catch (e: Exception) {
            cb(null)
        }
    }

    fun readBitmap(b: Bitmap, cb: (String?) -> Unit) {
        try {
            client.process(InputImage.fromBitmap(b, 0))
                .addOnSuccessListener { cb(it.text) }
                .addOnFailureListener { cb(null) }
        } catch (e: Exception) {
            cb(null)
        }
    }

    /** Busca el kilometraje total: un número de 4 a 7 cifras, sin hora ni decimales. */
    fun odometer(text: String, prev: Long?): Long? {
        val rx = Regex("(?<![\\d:.,])(\\d[\\d .]{2,8}\\d)(?![\\d:,])")
        val cands = ArrayList<Long>()
        for (m in rx.findAll(text)) {
            val v = m.groupValues[1].replace(" ", "").replace(".", "").toLongOrNull() ?: continue
            if (v in 1000..999999) cands.add(v)
        }
        if (cands.isEmpty()) return null
        if (prev != null) {
            val near = cands.filter { it >= prev && it - prev < 3000 }.minByOrNull { it - prev }
            if (near != null) return near
        }
        return cands.maxOrNull()
    }
}
EOF_ALVOLANTE
mkdir -p "proj/app/src/main/java/com/pablo/alvolante"
cat > 'proj/app/src/main/java/com/pablo/alvolante/MainActivity.kt' <<'EOF_ALVOLANTE'
package com.pablo.alvolante

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.provider.Settings
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : Activity() {
    private lateinit var sv: ScrollView
    private lateinit var root: LinearLayout
    private var screen = "home"
    private var camUri: Uri? = null
    private var camFin = false

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()
    private fun toast(s: String) { Toast.makeText(this, s, Toast.LENGTH_LONG).show() }

    // colores (fondo, título, subtítulo)
    private val VERDE = intArrayOf(Color.rgb(0xEA, 0xF3, 0xDE), Color.rgb(0x27, 0x50, 0x0A), Color.rgb(0x3B, 0x6D, 0x11))
    private val AZUL = intArrayOf(Color.rgb(0xE6, 0xF1, 0xFB), Color.rgb(0x0C, 0x44, 0x7C), Color.rgb(0x18, 0x5F, 0xA5))
    private val AMBAR = intArrayOf(Color.rgb(0xFA, 0xEE, 0xDA), Color.rgb(0x63, 0x38, 0x06), Color.rgb(0x85, 0x4F, 0x0B))
    private val GRIS = intArrayOf(Color.rgb(0xF1, 0xEF, 0xE8), Color.rgb(0x44, 0x44, 0x41), Color.rgb(0x5F, 0x5E, 0x5A))
    private val VIOLETA = intArrayOf(Color.rgb(0xEE, 0xED, 0xFE), Color.rgb(0x3C, 0x34, 0x89), Color.rgb(0x53, 0x4A, 0xB7))
    private val NEUTRO = Color.argb(0x1A, 0x88, 0x87, 0x80)

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        val saved = b?.getString("camUri")
        if (saved != null) camUri = Uri.parse(saved)
        camFin = b?.getBoolean("camFin") ?: false
        screen = b?.getString("screen") ?: "home"
        sv = ScrollView(this)
        root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setPadding(dp(18), dp(20), dp(18), dp(48))
        sv.addView(root)
        setContentView(sv)
        Zonas.cargar(this)
    }

    override fun onSaveInstanceState(o: Bundle) {
        super.onSaveInstanceState(o)
        val u = camUri
        if (u != null) o.putString("camUri", u.toString())
        o.putBoolean("camFin", camFin)
        o.putString("screen", screen)
    }

    override fun onResume() {
        super.onResume()
        show(screen)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (screen != "home") show("home") else super.onBackPressed()
    }

    private fun show(s: String) {
        screen = s
        root.removeAllViews()
        when (s) {
            "vara" -> vara()
            "jornada" -> jornada()
            "comb" -> comb()
            "conf" -> conf()
            "informe" -> informe()
            else -> home()
        }
        sv.scrollTo(0, 0)
    }

    // ---------- piezas ----------
    private fun round(c: Int, r: Int): GradientDrawable {
        val g = GradientDrawable()
        g.setColor(c)
        g.cornerRadius = dp(r).toFloat()
        return g
    }

    private fun tv(parent: LinearLayout, t: String, size: Float, bold: Boolean, color: Int? = null, top: Int = 4): TextView {
        val v = TextView(this)
        v.text = t
        v.textSize = size
        if (bold) v.setTypeface(v.typeface, Typeface.BOLD)
        if (color != null) v.setTextColor(color)
        v.setPadding(0, dp(top), 0, dp(2))
        parent.addView(v)
        return v
    }
    private fun h1(t: String) = tv(root, t, 28f, true, null, 0)
    private fun h2(t: String) = tv(root, t, 20f, true, null, 22)
    private fun p(t: String) = tv(root, t, 15f, false)
    private fun nota(t: String) = tv(root, t, 13f, false).also { it.alpha = 0.7f }

    private fun row(parent: LinearLayout = root): LinearLayout {
        val r = LinearLayout(this)
        r.orientation = LinearLayout.HORIZONTAL
        r.gravity = Gravity.CENTER_VERTICAL
        parent.addView(r)
        return r
    }

    private fun tile(parent: LinearLayout, icon: String, title: String, sub: String, c: IntArray, onClick: (() -> Unit)?) {
        val t = LinearLayout(this)
        t.orientation = LinearLayout.VERTICAL
        t.setPadding(dp(14), dp(14), dp(14), dp(14))
        t.background = round(c[0], 18)
        t.minimumHeight = dp(112)
        val lp = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        lp.setMargins(dp(5), dp(5), dp(5), dp(5))
        t.layoutParams = lp
        tv(t, icon, 26f, false, c[1], 0)
        tv(t, title, 17f, true, c[1], 6)
        tv(t, sub, 13f, false, c[2], 2)
        if (onClick != null) {
            t.isClickable = true
            t.setOnClickListener { onClick() }
        }
        parent.addView(t)
    }

    private fun metric(parent: LinearLayout, label: String, value: String) {
        val t = LinearLayout(this)
        t.orientation = LinearLayout.VERTICAL
        t.setPadding(dp(12), dp(10), dp(12), dp(10))
        t.background = round(NEUTRO, 12)
        val lp = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        lp.setMargins(dp(5), dp(5), dp(5), dp(5))
        t.layoutParams = lp
        tv(t, label, 13f, false, null, 0).alpha = 0.7f
        tv(t, value, 20f, true, null, 2)
        parent.addView(t)
    }

    private fun card(c: IntArray): LinearLayout {
        val box = LinearLayout(this)
        box.orientation = LinearLayout.VERTICAL
        box.setPadding(dp(16), dp(14), dp(16), dp(14))
        box.background = round(c[0], 16)
        val lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        lp.setMargins(0, dp(8), 0, dp(8))
        box.layoutParams = lp
        root.addView(box)
        return box
    }

    private fun btn(t: String, parent: LinearLayout = root, f: () -> Unit): Button {
        val b = Button(this)
        b.text = t
        b.isAllCaps = false
        b.textSize = 16f
        b.setOnClickListener { f() }
        parent.addView(b)
        return b
    }

    private fun back() {
        val b = TextView(this)
        b.text = "←  Inicio"
        b.textSize = 16f
        b.setPadding(0, dp(4), 0, dp(10))
        b.setOnClickListener { show("home") }
        root.addView(b)
    }

    private fun numEdit(label: String, decimal: Boolean = true): EditText {
        p(label)
        val e = EditText(this)
        e.inputType = InputType.TYPE_CLASS_NUMBER or (if (decimal) InputType.TYPE_NUMBER_FLAG_DECIMAL else 0)
        e.textSize = 18f
        root.addView(e)
        return e
    }

    private fun watch(e: EditText, f: (String) -> Unit) {
        e.addTextChangedListener(object : TextWatcher {
            override fun afterTextChanged(s: Editable?) { f(s?.toString() ?: "") }
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
        })
    }

    private fun field(label: String, key: String, def: String, decimal: Boolean = true): EditText {
        val e = numEdit(label, decimal)
        e.setText(Store.getS(this, key, def))
        watch(e) { Store.setS(this, key, it) }
        return e
    }

    private fun sw(text: String, key: String, def: Boolean) {
        val s = Switch(this)
        s.text = text
        s.textSize = 16f
        s.setPadding(0, dp(8), 0, dp(8))
        s.isChecked = Store.getB(this, key, def)
        s.setOnCheckedChangeListener { _, on -> Store.setB(this, key, on) }
        root.addView(s)
    }

    /** Botones de elección (uno marcado). */
    private fun opciones(items: List<Pair<String, String>>, actual: String, onSel: (String) -> Unit) {
        val r = row()
        r.setPadding(0, dp(4), 0, dp(4))
        val bs = ArrayList<Pair<Button, String>>()
        fun pintar(sel: String) {
            for ((b, v) in bs) {
                if (v == sel) { b.background = round(VERDE[0], 12); b.setTextColor(VERDE[1]); b.setTypeface(null, Typeface.BOLD) }
                else { b.background = round(NEUTRO, 12); b.setTextColor(GRIS[1]); b.setTypeface(null, Typeface.NORMAL) }
            }
        }
        for ((t, v) in items) {
            val b = Button(this)
            b.text = t
            b.isAllCaps = false
            b.textSize = 14f
            val lp = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            lp.setMargins(dp(3), 0, dp(3), 0)
            b.layoutParams = lp
            b.setOnClickListener { pintar(v); onSel(v) }
            r.addView(b)
            bs.add(Pair(b, v))
        }
        pintar(actual)
    }

    private fun num(e: EditText): Double? = e.text.toString().replace(".", "").replace(",", ".").trim().toDoubleOrNull()

    private fun isServiceOn(): Boolean {
        val s = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        return s.contains(packageName + "/")
    }

    private fun octavos(n16: Double): String {
        val n = Math.round(n16).toInt()
        return when (n) { 0 -> "vacío"; 4 -> "¼"; 8 -> "½"; 12 -> "¾"; 16 -> "lleno"; else -> "" + n + "/16" }
    }

    // ---------- inicio ----------
    private fun home() {
        val head = row()
        val title = tv(head, "Al volante", 28f, true, null, 0)
        title.layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        val on = isServiceOn()
        val chip = TextView(this)
        chip.text = if (on) "● Lectura activa" else "● Lectura apagada"
        chip.textSize = 13f
        chip.setTextColor(if (on) VERDE[1] else Color.rgb(0x79, 0x1F, 0x1F))
        chip.background = round(if (on) VERDE[0] else Color.rgb(0xFC, 0xEB, 0xEB), 10)
        chip.setPadding(dp(10), dp(5), dp(10), dp(5))
        chip.setOnClickListener { show("conf") }
        head.addView(chip)

        val m = row()
        m.setPadding(0, dp(10), 0, 0)
        val hoy = Store.informe(this, 1).firstOrNull()
        metric(m, "Hoy limpio (estimado)", if (hoy != null && hoy.viajes > 0) Fmt.money(hoy.limpio) else "—")
        val tq = Store.tanque(this)
        val n16 = tq.n16
        val aut = tq.autonomiaKm
        metric(m, "Combustible", if (n16 != null && aut != null) octavos(n16) + " · " + Fmt.num(aut, 0) + " km" else "—")

        val x = Evaluator.exig(this)
        val r1 = row()
        r1.setPadding(0, dp(6), 0, 0)
        val meta = if (Evaluator.useH(this)) Fmt.money(Store.getD(this, "obj_h", 15000.0)) + " h" else Fmt.money(Store.getD(this, "obj_km", 1000.0)) + " km"
        tile(r1, "🎯", "Tu vara", meta + " · " + arrayOf("Relajado", "Normal", "Exigente")[x], VERDE) { show("vara") }
        tile(r1, "⏱", "Jornada", Store.tableroCorto(this), AZUL) { show("jornada") }
        val r2 = row()
        val k = Store.aprendizaje(this).kml
        tile(r2, "⛽", "Combustible", if (k != null) Fmt.num(k, 1) + " km por litro" else "Aprendiendo", AMBAR) { show("comb") }
        tile(r2, "⚙", "Configuración", "Lectura, permisos", GRIS) { show("conf") }
        val r3 = row()
        tile(r3, "📊", "Informe", "Limpio por hora, días y mejores horarios", VIOLETA) { show("informe") }

        h2("Últimos pedidos")
        val list = Store.ultimosPedidos(this, 3)
        if (list.isEmpty()) p("Todavía no leí pedidos.")
        for (o in list) {
            val r = row()
            r.setPadding(0, dp(6), 0, dp(6))
            val lv = o.optInt("lv", 2).coerceIn(0, 4)
            val dot = TextView(this)
            dot.text = "●  "
            dot.textSize = 18f
            dot.setTextColor(Evaluator.NIVEL_DOT[lv])
            r.addView(dot)
            val orig = o.optString("o").ifEmpty { "?" }
            val dest = o.optString("d").ifEmpty { "?" }
            val acc = o.optBoolean("acc")
            val txt = TextView(this)
            txt.text = Store.hora(o.getLong("ts")) + " · " + orig + " → " + dest + (if (acc) " · tomado" else "")
            txt.textSize = 15f
            r.addView(txt, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            val pc = TextView(this)
            pc.text = if (o.has("pct")) Fmt.pct(o.getInt("pct")) else ""
            pc.textSize = 16f
            pc.setTypeface(pc.typeface, Typeface.BOLD)
            r.addView(pc)
            val ts = o.getLong("ts")
            r.setOnClickListener { Store.setTomado(this, ts, !acc); toast(if (acc) "Marcado como no tomado." else "Marcado como tomado."); show("home") }
        }
        if (list.isNotEmpty()) nota("Tocá un pedido para corregir si lo tomaste o no.")
    }

    // ---------- tu vara ----------
    private lateinit var regla: LinearLayout
    private lateinit var ejemplo: LinearLayout
    private var ejZona = false

    private fun vara() {
        back()
        h1("Tu vara")
        h2("1. ¿Cuánto querés ganar?")
        fun meta(label: String, keyUse: String, keyVal: String, def: String, defUse: Boolean) {
            val r = row()
            val cb = CheckBox(this)
            cb.isChecked = Store.getB(this, keyUse, defUse)
            cb.setOnCheckedChangeListener { _, on -> Store.setB(this, keyUse, on); refrescarVara() }
            r.addView(cb)
            val l = TextView(this)
            l.text = label
            l.textSize = 16f
            r.addView(l, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            val e = EditText(this)
            e.inputType = InputType.TYPE_CLASS_NUMBER
            e.textSize = 18f
            e.gravity = Gravity.END
            e.setText(Store.getS(this, keyVal, def))
            watch(e) { Store.setS(this, keyVal, it); refrescarVara() }
            r.addView(e, LinearLayout.LayoutParams(dp(130), ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        meta("Por hora (\$)", "use_h", "obj_h", "15000", true)
        meta("Por km (\$)", "use_km", "obj_km", "1000", Store.getD(this, "obj_km", 1000.0) > 0)
        nota("Si tildás los dos, cuentan mitad y mitad. Destildado no cuenta.")

        h2("2. ¿Qué tan exigente sos?")
        opciones(listOf(Pair("Relajado", "0"), Pair("Normal", "1"), Pair("Exigente", "2")), Store.getS(this, "exig", "1")) {
            Store.setS(this, "exig", it); refrescarVara()
        }
        regla = LinearLayout(this)
        regla.orientation = LinearLayout.VERTICAL
        root.addView(regla)

        h2("3. Zonas")
        p("Zona de destino (aprende sola: tus zonas, la demanda y los verdes que dejás pasar)")
        opciones(listOf(Pair("No influye", "0"), Pair("Influye", "1")), if (Store.getB(this, "zona_dest", true)) "1" else "0") {
            Store.setB(this, "zona_dest", it == "1"); refrescarVara()
        }
        p("Zona peligrosa (barrios populares de Ciudad y Provincia, o cuando DiDi marca zona de riesgo)")
        opciones(listOf(Pair("No influye", "0"), Pair("Resta 15%", "15"), Pair("Resta 35%", "35")), Store.getS(this, "zp", "15")) {
            Store.setS(this, "zp", it); refrescarVara()
        }
        nota("Resta más si además es de noche (21 a 6 h), en efectivo o con pasajero nuevo.")

        h2("Así se vería un viaje de ejemplo")
        val sw = Switch(this)
        sw.text = "Destino en zona peligrosa"
        sw.textSize = 15f
        sw.isChecked = ejZona
        sw.setOnCheckedChangeListener { _, on -> ejZona = on; refrescarVara() }
        root.addView(sw)
        ejemplo = LinearLayout(this)
        ejemplo.orientation = LinearLayout.VERTICAL
        root.addView(ejemplo)
        nota("\$9.900 · 8,4 km · 32 min, contando ir a buscarlo")
        refrescarVara()
    }

    private fun refrescarVara() {
        if (!::regla.isInitialized || screen != "vara") return
        regla.removeAllViews()
        val x = Evaluator.exig(this)
        val useH = Evaluator.useH(this)
        val useK = Evaluator.useK(this)
        val base = if (useH) Store.getD(this, "obj_h", 15000.0) else if (useK) Store.getD(this, "obj_km", 1000.0) else 0.0
        val band = LinearLayout(this)
        band.orientation = LinearLayout.HORIZONTAL
        for (i in 0..4) {
            val v = View(this)
            v.background = round(Evaluator.NIVEL_BG[i], 4)
            val lp = LinearLayout.LayoutParams(0, dp(14), 1f)
            lp.setMargins(dp(1), dp(8), dp(1), 0)
            band.addView(v, lp)
        }
        regla.addView(band)
        if (base > 0) {
            val marks = LinearLayout(this)
            marks.orientation = LinearLayout.HORIZONTAL
            val vals = arrayOf("", Fmt.money(base * Evaluator.EX_A[x]), Fmt.money(base), Fmt.money(base * (1 + Evaluator.EX_M[x])), Fmt.money(base * (1 + Evaluator.EX_E[x])))
            for (s in vals) {
                val t = TextView(this)
                t.text = s
                t.textSize = 12f
                marks.addView(t, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            }
            regla.addView(marks)
            tv(regla, "Dónde empieza cada color, en pesos " + (if (useH) "por hora" else "por km") + ": amarillo, verde, muy bueno y excelente.", 12f, false).alpha = 0.7f
        } else {
            tv(regla, "Tildá al menos una meta.", 13f, false)
        }
        ejemplo.removeAllViews()
        val pe = Pedido(9900.0, null, 3, 0.3, 29, 8.1, null, if (ejZona) "Ejemplo" else null, null, null)
        val r = if (ejZona) Riesgo(false, null, "un barrio popular", false, false) else Riesgo(false, null, null, false, false)
        val e = Evaluator.eval(this, pe, r)
        val box = LinearLayout(this)
        box.orientation = LinearLayout.VERTICAL
        box.setPadding(dp(16), dp(12), dp(16), dp(12))
        box.background = round(e.color, 16)
        val lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        lp.setMargins(0, dp(6), 0, dp(4))
        box.layoutParams = lp
        val top = LinearLayout(this)
        top.orientation = LinearLayout.HORIZONTAL
        top.gravity = Gravity.CENTER_VERTICAL
        val t1 = TextView(this)
        t1.text = e.label + " · \$9.900"
        t1.textSize = 17f
        t1.setTypeface(null, Typeface.BOLD)
        t1.setTextColor(e.textColor)
        top.addView(t1, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val t2 = TextView(this)
        t2.text = Fmt.pct(e.pct)
        t2.textSize = 28f
        t2.setTypeface(null, Typeface.BOLD)
        t2.setTextColor(e.textColor)
        top.addView(t2)
        box.addView(top)
        val t3 = TextView(this)
        t3.text = Fmt.money(e.perHour) + " por hora · " + Fmt.money(e.perKm) + " por km" + (if (e.riesgo.isNotEmpty()) "\n" + e.riesgo else "")
        t3.textSize = 13f
        t3.setTextColor(e.textColor)
        box.addView(t3)
        ejemplo.addView(box)
    }

    // ---------- jornada ----------
    private fun jornada() {
        back()
        h1("Jornada de hoy")
        p("Cargá el kilometraje y cuánto combustible tenés al empezar y al terminar. Con eso la app aprende sola el consumo.")
        fun estado(w: String): String {
            val r = Store.tableroHoy(this, w) ?: return "Tocá para cargar"
            var s = if (r.has("km")) Fmt.int(r.getLong("km")) + " km" else "sin km"
            if (r.has("n16")) s += " · " + octavos(r.getInt("n16").toDouble())
            return s + " · " + Store.hora(r.getLong("ts"))
        }
        val r = row()
        r.setPadding(0, dp(8), 0, 0)
        tile(r, "🌅", "Al empezar", estado("ini"), AZUL) { dialogoTablero(false, null) }
        tile(r, "🌙", "Al terminar", estado("fin"), if (Store.tableroHoy(this, "ini") != null) AZUL else GRIS) { dialogoTablero(true, null) }
        val km = Store.kmHoy(this)
        if (km != null) metric(row(), "Hiciste hoy", Fmt.int(km) + " km")
    }

    private fun dialogoTablero(fin: Boolean, kmFoto: Long?) {
        val box = LinearLayout(this)
        box.orientation = LinearLayout.VERTICAL
        box.setPadding(dp(22), dp(8), dp(22), 0)
        val ultimo = Store.ultimoKm(this)
        val e = EditText(this)
        e.inputType = InputType.TYPE_CLASS_NUMBER
        e.textSize = 22f
        e.hint = "Kilometraje"
        var cb: CheckBox? = null
        if (!fin && ultimo != null && kmFoto == null) {
            val c = CheckBox(this)
            c.text = "Igual que el último cierre (" + Fmt.int(ultimo) + " km)"
            c.textSize = 15f
            c.isChecked = true
            e.setText(ultimo.toString())
            e.isEnabled = false
            c.setOnCheckedChangeListener { _, on -> e.isEnabled = !on; if (on) e.setText(ultimo.toString()) }
            box.addView(c)
            cb = c
        } else if (kmFoto != null) {
            e.setText(kmFoto.toString())
        }
        box.addView(e)
        val tN = TextView(this)
        tN.textSize = 15f
        tN.setPadding(0, dp(14), 0, 0)
        box.addView(tN)
        val med = Medidor(this)
        val est = Store.tanque(this).n16
        med.onCambio = { n -> tN.text = "Combustible ahora: " + octavos(n.toDouble()) }
        med.nivel = if (est != null) Math.round(est).toInt() else (Store.ultimoN16(this) ?: 8)
        box.addView(med)
        val foto = Button(this)
        foto.text = "Leer el kilometraje con foto (opcional)"
        foto.isAllCaps = false
        box.addView(foto)
        val dlg = AlertDialog.Builder(this)
            .setTitle(if (fin) "Al terminar" else "Al empezar")
            .setView(box)
            .setPositiveButton("Guardar") { _, _ ->
                val km = e.text.toString().trim().toLongOrNull()
                Store.setTablero(this, Store.today(), if (fin) "fin" else "ini", km, med.nivel)
                show(screen)
                toast("Guardado.")
            }
            .setNegativeButton("Cancelar", null)
            .create()
        foto.setOnClickListener { dlg.dismiss(); fotoTablero(fin) }
        dlg.show()
        if (cb == null && kmFoto == null && fin && ultimo != null) e.hint = "Último: " + Fmt.int(ultimo)
    }

    // ---------- combustible ----------
    private fun comb() {
        back()
        h1("Combustible")
        val a = Store.aprendizaje(this)
        val box = card(AMBAR)
        val kml = a.kml
        tv(box, when (a.tipo) { "real" -> "Consumo real (aprendido)"; "aproximado" -> "Consumo aproximado"; "manual" -> "Consumo cargado a mano"; else -> "Consumo" }, 13f, false, AMBAR[2], 0)
        tv(box, if (kml != null) Fmt.num(kml, 1) + " km por litro" else "Aprendiendo", 24f, true, AMBAR[1], 2)
        val ck = Store.costoKm(this)
        tv(box, if (ck != null) Fmt.money(ck) + " de combustible por km" else "Cargá inicio y fin de jornada unos días, y cada carga, y lo calculo solo.", 13f, false, AMBAR[2], 2)
        val cap = a.cap
        if (cap != null) tv(box, "Tanque: unos " + Fmt.num(cap, 0) + " litros (aprendido)", 13f, false, AMBAR[2], 2)

        val tq = Store.tanque(this)
        val n16 = tq.n16
        if (n16 != null) {
            h2("Ahora")
            val med = Medidor(this)
            med.nivel = Math.round(n16).toInt()
            med.isEnabled = false
            med.setOnTouchListener { _, _ -> true }
            root.addView(med)
            val aut = tq.autonomiaKm
            p("Estimado: " + octavos(n16) + (if (aut != null) " · alcanza para unos " + Fmt.num(aut, 0) + " km" else "") +
                (if (tq.viajes != null) ", unos " + tq.viajes + " viajes como los de hoy" else "") + (if (tq.aprox) " (aproximado)" else ""))
            if (n16 < 4) p("⚠ Te queda menos de ¼: conviene cargar donde te quede cómodo.")
            nota("Se corrige solo cuando cargás el inicio de la jornada.")
        }

        h2("Nueva carga")
        p("Poné dos de los tres datos y calculo el tercero.")
        val eImp = numEdit("Importe pagado (\$)")
        val eLit = numEdit("Litros cargados")
        val ePre = numEdit("Precio por litro (\$)")
        btn("Guardar carga") { guardarCarga(eImp, eLit, ePre) }
        p(Store.cargasResumen(this))
    }

    // ---------- informe ----------
    private fun informe() {
        back()
        h1("Informe")
        val dias = Store.informe(this, 7)
        val com = Store.comisionTasa(this)
        val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        val dn = arrayOf("Dom", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb")
        val etiquetas = Array(dias.size) { i ->
            val d = try { sdf.parse(dias[i].fecha) } catch (e: Exception) { null }
            if (d == null) "" else { val cal = java.util.Calendar.getInstance(); cal.time = d; dn[cal.get(java.util.Calendar.DAY_OF_WEEK) - 1] }
        }
        h2("Limpio por día (últimos 7)")
        root.addView(Barras(this, DoubleArray(dias.size) { dias[it].limpio }, etiquetas))
        var hs = 0.0; var limpio = 0.0; var cobrado = 0.0; var comb = 0.0; var comi = 0.0; var vj = 0
        for (d in dias) { hs += d.horas; limpio += d.limpio; cobrado += d.cobrado; comb += d.combustible ?: 0.0; comi += d.comision; vj += d.viajes }
        val box = card(VIOLETA)
        tv(box, "Últimos 7 días", 13f, false, VIOLETA[2], 0)
        tv(box, if (hs >= 0.5) Fmt.money(limpio / hs) + " limpio por hora" else Fmt.money(limpio) + " limpio", 24f, true, VIOLETA[1], 2)
        tv(box, vj.toString() + " viajes · " + Fmt.num(hs, 1) + " h conectado\nCobrado " + Fmt.money(cobrado) + " · comisión " + Fmt.money(comi) + " · combustible " + Fmt.money(comb), 13f, false, VIOLETA[2], 4)
        for (i in dias.indices.reversed()) {
            val d = dias[i]
            if (d.viajes == 0 && d.horas < 0.1) continue
            p(etiquetas[i] + " " + d.fecha.substring(8) + ": " + Fmt.num(d.horas, 1) + " h · " + d.viajes + " viajes · limpio " + Fmt.money(d.limpio) +
                (if (d.horas >= 0.5) " (" + Fmt.money(d.limpio / d.horas) + " por hora)" else ""))
        }
        nota("Cuenta los viajes que la app detectó como tomados (los podés corregir en el inicio) y el tiempo con DiDi abierto en pantalla.")

        h2("Comisión de DiDi")
        p((if (com.second) "Tu comisión real: " else "Comisión estimada (todavía sin datos tuyos): ") + Fmt.num(com.first * 100, 0) + "%")
        val ep = numEdit("Ganancias de la semana pasada que muestra DiDi (\$)")
        btn("Guardar") {
            val v = num(ep)
            if (v == null || v <= 0) toast("Poné el monto.") else { Store.guardarPagoSemana(this, v); toast("Guardado."); show("informe") }
        }
        nota("Con ese número la app compara lo que te pagó DiDi con lo que sumaron tus viajes y saca tu comisión de verdad.")

        h2("Mejores horarios")
        val fr = Store.franjas(this)
        if (fr.isEmpty()) p("Todavía faltan datos: necesito al menos 5 pedidos en una franja.")
        for (f in fr.take(4)) {
            p(f.desde.toString() + " a " + (f.desde + 3) + " h: pagan " + Fmt.money(f.porHora) + " por hora en promedio" +
                (if (f.pedidosPorHora != null) " · " + Fmt.num(f.pedidosPorHora, 1) + " pedidos por hora conectado" else "") + " (" + f.pedidos + " pedidos)")
        }
    }

    // ---------- configuración ----------
    private fun conf() {
        back()
        h1("Configuración")
        h2("Lectura de DiDi")
        p(if (isServiceOn()) "Activa. Cuando entre un pedido aparece el semáforo arriba de la pantalla." else "Apagada. Activala para ver el semáforo.")
        if (Build.VERSION.SDK_INT < 30) p("⚠ Tu Android es anterior a la versión 11: no permite leer la tarjeta con foto, y DiDi no deja leerla como texto.")
        btn("Activar lectura de DiDi") { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
        btn("Probar el semáforo") {
            val s = DidiReaderService.instance
            if (s == null) toast("Primero activá la lectura de DiDi.") else { s.test(); toast("Mirá arriba de la pantalla.") }
        }
        btn("Que Samsung no la apague (batería sin restricciones)") {
            try {
                startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + packageName)))
            } catch (e: Exception) {
                try { startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) } catch (e2: Exception) { toast("No pude abrir el ajuste de batería.") }
            }
        }
        sw("Leer la tarjeta con foto cuando DiDi no deja leer el texto", "ocr", true)
        field("Altura de la burbuja desde arriba", "overlay_y", "70", false)

        h2("Permisos")
        p("Si Android no te deja activar la lectura: tocá \"Abrir info de la app\", los tres puntitos de arriba y \"Permitir ajustes restringidos\".")
        btn("Abrir info de la app") {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + packageName)))
        }

        h2("Zonas")
        val nz = Zonas.cantidad()
        p(if (nz > 0) "Zonas peligrosas cargadas: " + nz + " polígonos oficiales de barrios populares." else if (nz == 0) "No hay polígonos de zonas peligrosas en esta versión." else "Cargando zonas peligrosas…")
        p("Para enseñarle tus zonas: prendé \"Modo aprender\", abrí el historial de viajes en DiDi y bajá despacio. Apagalo cuando termines.")
        sw("Modo aprender", "aprender", false)
        btn("Leer capturas del historial") {
            val i = Intent(Intent.ACTION_OPEN_DOCUMENT)
            i.addCategory(Intent.CATEGORY_OPENABLE)
            i.type = "image/*"
            i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            startActivityForResult(i, 3)
        }
        p(Store.zonasResumen(this))
        btn("Borrar zonas aprendidas") {
            AlertDialog.Builder(this).setMessage("¿Borrar todas las zonas aprendidas?")
                .setPositiveButton("Borrar") { _, _ -> Store.clearZonas(this); show("conf") }
                .setNegativeButton("Cancelar", null).show()
        }

        h2("Diagnóstico")
        btn("Ver lo que leo de DiDi") { verLeido() }
    }

    // ---------- acciones ----------
    private fun guardarCarga(eImp: EditText, eLit: EditText, ePre: EditText) {
        var imp = num(eImp)
        var lit = eLit.text.toString().replace(",", ".").trim().toDoubleOrNull()
        var pre = num(ePre)
        if (imp == null && lit != null && pre != null) imp = lit * pre
        if (lit == null && imp != null && pre != null && pre > 0) lit = imp / pre
        if (pre == null && imp != null && lit != null && lit > 0) pre = imp / lit
        if (imp == null || lit == null || pre == null || imp <= 0 || lit <= 0) { toast("Completá dos de los tres datos."); return }
        Store.addCarga(this, imp, lit, pre)
        toast("Carga guardada: " + Fmt.num(lit, 1) + " litros a " + Fmt.money(pre) + " el litro.")
        show("comb")
    }

    private fun fotoTablero(fin: Boolean) {
        camFin = fin
        try {
            val v = ContentValues()
            v.put(MediaStore.Images.Media.DISPLAY_NAME, "tablero_" + System.currentTimeMillis() + ".jpg")
            v.put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            v.put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/AlVolante")
            val u = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, v)
            camUri = u
            val i = Intent(MediaStore.ACTION_IMAGE_CAPTURE)
            i.putExtra(MediaStore.EXTRA_OUTPUT, u)
            i.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivityForResult(i, 1)
        } catch (e: Exception) {
            toast("No pude abrir la cámara.")
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(req: Int, res: Int, data: Intent?) {
        super.onActivityResult(req, res, data)
        if (req == 1) {
            val u = camUri ?: return
            if (res != RESULT_OK) return
            toast("Leyendo el tablero…")
            val fin = camFin
            Ocr.read(this, u) { txt ->
                val km = Ocr.odometer(txt ?: "", Store.ultimoKm(this))
                if (km == null) toast("No pude leer el kilometraje. Escribilo a mano.")
                dialogoTablero(fin, km)
            }
        }
        if (req == 3 && res == RESULT_OK && data != null) {
            val uris = ArrayList<Uri>()
            val cd = data.clipData
            if (cd != null) { for (i in 0 until cd.itemCount) uris.add(cd.getItemAt(i).uri) }
            else { val d = data.data; if (d != null) uris.add(d) }
            if (uris.isNotEmpty()) leerCapturas(uris)
        }
    }

    private fun leerCapturas(uris: List<Uri>) {
        toast("Leyendo " + uris.size + " capturas…")
        val total = intArrayOf(0)
        fun next(i: Int) {
            if (i >= uris.size) {
                toast("Listo: sumé " + total[0] + " paradas nuevas a tus zonas.")
                show(screen)
                return
            }
            Ocr.read(this, uris[i]) { txt ->
                if (txt != null) total[0] += Store.learnLines(this, txt.split("\n"))
                next(i + 1)
            }
        }
        next(0)
    }

    private fun verLeido() {
        val pk = synchronized(DidiReaderService.seenPkgs) { DidiReaderService.seenPkgs.joinToString("\n") }
        val ll = DidiReaderService.lastLines
        val txt = "Versión " + (try { packageManager.getPackageInfo(packageName, 0).versionName } catch (e: Exception) { "?" }) +
            "\n\nApps que vi:\n" + (if (pk.isEmpty()) "(ninguna todavía)" else pk) +
            "\n\nÚltimo texto leído de DiDi:\n" + (if (ll.isEmpty()) "(nada todavía)" else ll.joinToString("\n")) +
            "\n\nÚltimas pantallas de DiDi con minutos:\n" + Store.snapsTexto(this)
        val t = TextView(this)
        t.text = txt
        t.setTextIsSelectable(true)
        t.setPadding(dp(22), dp(10), dp(22), dp(10))
        val s = ScrollView(this)
        s.addView(t)
        AlertDialog.Builder(this).setTitle("Lo que leo").setView(s)
            .setPositiveButton("Copiar") { _, _ ->
                val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("al-volante", txt))
                toast("Copiado. Pegámelo en el chat si algo no anda.")
            }
            .setNegativeButton("Cerrar", null).show()
    }
}
EOF_ALVOLANTE
mkdir -p "proj/app/src/main/java/com/pablo/alvolante"
cat > 'proj/app/src/main/java/com/pablo/alvolante/Model.kt' <<'EOF_ALVOLANTE'
package com.pablo.alvolante

import android.content.Context
import android.graphics.Color
import java.text.NumberFormat
import java.util.Calendar
import java.util.Locale

data class Pedido(
    val price: Double,
    val mult: String?,
    val pMin: Int,
    val pKm: Double,
    val tMin: Int,
    val tKm: Double,
    val origin: String?,
    val dest: String?,
    val originAddr: String?,
    val destAddr: String?,
    val rechazoLibre: Boolean = false,
    val efectivo: Boolean = false,
    val ptp: Boolean = false,
    val nuevo: Boolean = false,
    val riesgoDidi: Boolean = false
)

/** Resultado del chequeo de zona peligrosa (polígonos oficiales). */
data class Riesgo(val pendiente: Boolean, val origen: String?, val destino: String?, val cerca: Boolean, val sinUbicar: Boolean)

data class Eval(
    val perKm: Double,
    val perHour: Double,
    val score: Double,
    val pct: Int,
    val level: Int,
    val color: Int,
    val textColor: Int,
    val label: String,
    val zona: String,
    val extras: String,
    val riesgo: String,
    val fuel: Double?
)

object Fmt {
    private val loc: Locale = Locale.forLanguageTag("es-AR")
    fun int(v: Long): String = NumberFormat.getIntegerInstance(loc).format(v)
    fun money(v: Double): String {
        if (v.isNaN() || v.isInfinite()) return "-"
        return (if (v < 0) "-" else "") + "\$" + NumberFormat.getIntegerInstance(loc).format(Math.round(Math.abs(v)))
    }
    fun num(v: Double, d: Int): String {
        val f = NumberFormat.getNumberInstance(loc)
        f.maximumFractionDigits = d
        f.minimumFractionDigits = 0
        return f.format(v)
    }
    fun pct(p: Int): String = if (p >= 0) "+" + p + "%" else "−" + (-p) + "%"
}

internal class Seg(val min: Int, val km: Double, val idx: Int)

object Parser {
    private val segRx = Regex("(\\d+)\\s*min\\.?\\s*\\(?\\s*([\\d.,]+)\\s*(km|m)\\b\\s*\\)?", RegexOption.IGNORE_CASE)
    private val priceLine = Regex("^[\\\$S]\\s*(\\d{1,3}(?:\\.\\d{3})+|\\d+)(?:,\\d{1,2})?$")
    private val priceAny = Regex("\\$\\s*([\\d.]+(?:,\\d{1,2})?)")
    private val multRx = Regex("(\\d+[.,]\\d+)\\s*x\\b")
    private val decDot = Regex("\\.\\d{1,2}$")
    val minRx = Regex("\\d+\\s*min", RegexOption.IGNORE_CASE)
    private val aceptarRx = Regex("Aceptar\\s*[\\\$S]\\s*(\\d{1,3}(?:\\.\\d{3})+|\\d+)", RegexOption.IGNORE_CASE)
    private val cpRx = Regex("\\bC(1\\d{3})(?:[A-Z]{3})?\\b")
    private val viajesRx = Regex("(\\d[\\d.]*)\\s*viajes", RegexOption.IGNORE_CASE)
    private val numStart = Regex("^\\d{1,5}\\s*,")
    private val calleRx = Regex("([^,]*?[A-Za-zÁÉÍÓÚÑáéíóúñ.]\\s+\\d{1,5})\\s*,")

    fun money(s: String): Double? = s.replace(".", "").replace(",", ".").toDoubleOrNull()

    fun clean(s: String): String = s.replace(Char(0xA0), ' ').replace(Char(0x202F), ' ').trim()

    /** "Tucumán 3231, CABA - Balvanera" -> "Balvanera" */
    fun barrioOf(line: String): String? {
        val i = line.lastIndexOf(" - ")
        if (i < 0) return null
        val b = line.substring(i + 3).trim()
        if (b.length < 3 || b.length > 40 || b.any { it.isDigit() }) return null
        return b
    }

    /** Barrio si DiDi lo da ("... - Balvanera"); si no, el código postal ("CP 1424"). */
    fun zonaOf(line: String): String? {
        val b = barrioOf(line)
        if (b != null) return b
        val m = cpRx.find(line) ?: return null
        return "CP " + m.groupValues[1]
    }

    fun isAddress(l: String): Boolean {
        if (zonaOf(l) == null) return false
        val u = l.uppercase()
        return l.contains(",") || u.contains("CABA") || u.contains("BUENOS AIRES")
    }

    /** Arma una dirección que el buscador de mapas de Android pueda ubicar. */
    fun geoQuery(addr: String?): String? {
        if (addr == null) return null
        val a = addr.replace(Regex("\\s*-\\s*N°\\s*\\S+"), "").replace("...", "").trim()
        val m = calleRx.findAll(a).lastOrNull() ?: return null
        val calle = m.groupValues[1].trim()
        val u = a.uppercase()
        val ciudad = when {
            cpRx.containsMatchIn(a) || u.contains("CABA") || u.contains("CDAD") -> "Ciudad Autónoma de Buenos Aires"
            else -> a.substring(m.range.last + 1).substringBefore(" - ").substringBefore(",").trim().ifEmpty { "Buenos Aires" }
        }
        return calle + ", " + ciudad + ", Argentina"
    }

    fun parse(raw: List<String>): Pedido? {
        val lines = raw.map { clean(it) }.filter { it.isNotEmpty() }
        val joined = lines.joinToString("  ")
        val segs = ArrayList<Seg>()
        var firstSeg = -1
        for (m in segRx.findAll(joined)) {
            val mins = m.groupValues[1].toIntOrNull() ?: continue
            val s = m.groupValues[2]
            val unit = m.groupValues[3].lowercase()
            val norm = when {
                s.contains(",") -> s.replace(".", "").replace(",", ".")
                unit == "km" && decDot.containsMatchIn(s) -> s
                else -> s.replace(".", "")
            }
            var d = norm.toDoubleOrNull() ?: continue
            if (unit == "m") d /= 1000.0
            if (firstSeg < 0) firstSeg = m.range.first
            segs.add(Seg(mins, d, m.range.first))
        }
        if (segs.size < 2) return null

        // Poné Tu Precio: vale el precio del botón "Aceptar", no las contraofertas
        var price: Double? = aceptarRx.find(joined)?.let { money(it.groupValues[1]) }
        val area = if (firstSeg > 0) joined.substring(0, firstSeg) else joined
        if (price == null) {
            for (l in area.split("  ")) {
                val m = priceLine.find(l.trim()) ?: continue
                price = money(m.groupValues[1])
                if (price != null) break
            }
        }
        if (price == null) {
            price = priceAny.findAll(area).mapNotNull { money(it.groupValues[1]) }.maxOrNull()
                ?: priceAny.findAll(joined).mapNotNull { money(it.groupValues[1]) }.maxOrNull()
        }
        val pr = price ?: return null
        if (pr < 100) return null

        var mult: String? = null
        for (l in lines) {
            val m = multRx.find(l)
            if (m != null) { mult = m.groupValues[1]; break }
        }
        val low = joined.lowercase()
        val libre = low.contains("rechazo permitido")
        val efectivo = low.contains("efectivo")
        val ptp = low.contains("poné tu precio") || low.contains("pone tu precio")
        val riesgo = low.contains("zona de riesgo")
        val vj = viajesRx.find(joined)?.groupValues?.get(1)?.replace(".", "")?.toIntOrNull()
        val nuevo = low.contains("nuevo usuario") || low.contains("pasajero nuevo") || (vj != null && vj < 20)

        // direcciones: si el OCR partió la dirección en dos renglones, se juntan
        val addrs = ArrayList<String>()
        for (i in lines.indices) {
            val l = lines[i]
            if (!isAddress(l)) continue
            if (numStart.containsMatchIn(l) && i > 0 && !isAddress(lines[i - 1])) addrs.add(lines[i - 1] + " " + l) else addrs.add(l)
        }
        val p = segs[0]
        val t = segs[1]
        val oA = addrs.getOrNull(0)
        val dA = addrs.getOrNull(1)
        return Pedido(pr, mult, p.min, p.km, t.min, t.km, oA?.let { zonaOf(it) }, dA?.let { zonaOf(it) }, oA, dA,
            libre, efectivo, ptp, nuevo, riesgo)
    }
}

object Evaluator {
    val NIVEL_BG = intArrayOf(
        Color.rgb(0xA3, 0x2D, 0x2D),
        Color.rgb(0xFA, 0xC7, 0x75),
        Color.rgb(0x63, 0x99, 0x22),
        Color.rgb(0x3B, 0x6D, 0x11),
        Color.rgb(0x17, 0x34, 0x04)
    )
    val NIVEL_FG = intArrayOf(
        Color.rgb(0xFC, 0xEB, 0xEB),
        Color.rgb(0x41, 0x24, 0x02),
        Color.rgb(0x17, 0x34, 0x04),
        Color.rgb(0xEA, 0xF3, 0xDE),
        Color.rgb(0xEA, 0xF3, 0xDE)
    )
    val NIVEL_DOT = intArrayOf(
        Color.rgb(0xE2, 0x4B, 0x4A),
        Color.rgb(0xBA, 0x75, 0x17),
        Color.rgb(0x63, 0x99, 0x22),
        Color.rgb(0x3B, 0x6D, 0x11),
        Color.rgb(0x27, 0x50, 0x0A)
    )
    val NIVEL_TXT = arrayOf("No conviene", "Justo", "Conviene", "★ Muy bueno", "★★ Excelente")

    // Relajado, Normal, Exigente: amarillo desde, muy bueno desde, excelente desde
    val EX_A = doubleArrayOf(0.80, 0.85, 0.90)
    val EX_M = doubleArrayOf(0.30, 0.25, 0.20)
    val EX_E = doubleArrayOf(0.60, 0.50, 0.40)

    fun exig(c: Context): Int = Store.getS(c, "exig", "1").toIntOrNull()?.coerceIn(0, 2) ?: 1
    fun useH(c: Context): Boolean = Store.getB(c, "use_h", true) && Store.getD(c, "obj_h", 15000.0) > 0
    fun useK(c: Context): Boolean = Store.getB(c, "use_km", Store.getD(c, "obj_km", 1000.0) > 0) && Store.getD(c, "obj_km", 1000.0) > 0

    fun nivel(c: Context, score: Double): Int {
        val x = exig(c)
        return when {
            score >= 1.0 + EX_E[x] -> 4
            score >= 1.0 + EX_M[x] -> 3
            score >= 1.0 -> 2
            score >= EX_A[x] -> 1
            else -> 0
        }
    }

    fun nocheAhora(): Boolean {
        val h = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
        return h >= 21 || h < 6
    }

    fun eval(c: Context, p: Pedido, r: Riesgo?): Eval {
        val km = (p.pKm + p.tKm).coerceAtLeast(0.1)
        val min = (p.pMin + p.tMin).coerceAtLeast(1)
        val perKm = p.price / km
        val perHour = p.price / (min / 60.0)
        val rs = ArrayList<Double>()
        if (useH(c)) rs.add(perHour / Store.getD(c, "obj_h", 15000.0))
        if (useK(c)) rs.add(perKm / Store.getD(c, "obj_km", 1000.0))
        var score = if (rs.isEmpty()) 1.0 else rs.average()

        // zona de destino aprendida: habitual + demanda - no deseada
        var zona = if (p.dest != null) "Destino: " + p.dest else ""
        if (Store.getB(c, "zona_dest", true) && p.dest != null) {
            val z = Store.zonaFactor(c, p.dest)
            score *= (1 + z.first)
            if (z.second.isNotEmpty()) zona += " · " + z.second
        }

        // zona peligrosa
        var riesgoTxt = ""
        val zp = Store.getD(c, "zp", 15.0) / 100.0
        val enZona = p.riesgoDidi || (r != null && (r.origen != null || r.destino != null))
        if (zp > 0) {
            if (enZona) {
                var d = zp
                val ag = ArrayList<String>()
                if (nocheAhora()) { d += 0.10; ag.add("de noche") }
                if (p.efectivo) { d += 0.05; ag.add("efectivo") }
                if (p.nuevo) { d += 0.10; ag.add("pasajero nuevo") }
                score *= (1 - d.coerceAtMost(0.8))
                val donde = when {
                    p.riesgoDidi -> "DiDi la marca como zona de riesgo"
                    r?.destino != null -> "destino en " + r.destino
                    else -> "origen en " + (r?.origen ?: "")
                }
                riesgoTxt = "⚠ Zona peligrosa: " + donde + (if (ag.isNotEmpty()) " · " + ag.joinToString(", ") else "") +
                    (if (p.riesgoDidi) " · rechazarlo no te baja la tasa" else "")
            } else if (r != null && r.cerca) {
                riesgoTxt = "Cerca de un barrio popular"
            } else if (r != null && r.pendiente) {
                riesgoTxt = "Zona: verificando…"
            } else if (r != null && r.sinUbicar) {
                riesgoTxt = "Zona: no pude ubicar la dirección"
            }
        }

        val level = nivel(c, score)
        val pct = Math.round((score - 1.0) * 100).toInt()
        val ex2 = ArrayList<String>()
        if (p.mult != null) ex2.add("⚡" + p.mult + "x")
        if (p.rechazoLibre && level <= 1) ex2.add("Rechazo libre")
        if (p.pMin > 10 || (p.tKm > 0 && p.pKm > 0.4 * p.tKm)) ex2.add("Búsqueda lejana")
        val ck = Store.costoKm(c)
        return Eval(perKm, perHour, score, pct, level, NIVEL_BG[level], NIVEL_FG[level], NIVEL_TXT[level],
            zona, ex2.joinToString(" · "), riesgoTxt, if (ck != null) ck * km else null)
    }
}
EOF_ALVOLANTE
mkdir -p "proj/app/src/main/java/com/pablo/alvolante"
cat > 'proj/app/src/main/java/com/pablo/alvolante/Store.kt' <<'EOF_ALVOLANTE'
package com.pablo.alvolante

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.Normalizer
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

internal class Punto(val ts: Long, val km: Long, val n16: Int?)

class Aprendizaje(val kml: Double?, val cap: Double?, val tipo: String, val dias: Int)

class Tanque(val n16: Double?, val litros: Double?, val autonomiaKm: Double?, val viajes: Int?, val aprox: Boolean)

class Dia(val fecha: String, val horas: Double, val viajes: Int, val cobrado: Double, val km: Double,
          val combustible: Double?, val comision: Double, val limpio: Double)

class Franja(val desde: Int, val pedidos: Int, val porHora: Double, val pedidosPorHora: Double?)

object Store {
    private fun file(c: Context, n: String) = File(c.filesDir, n)
    private fun obj(c: Context, n: String): JSONObject = try { JSONObject(file(c, n).readText()) } catch (e: Exception) { JSONObject() }
    private fun arr(c: Context, n: String): JSONArray = try { JSONArray(file(c, n).readText()) } catch (e: Exception) { JSONArray() }
    private fun save(c: Context, n: String, s: String) { try { file(c, n).writeText(s) } catch (e: Exception) { } }
    private fun prefs(c: Context) = c.getSharedPreferences("cfg", Context.MODE_PRIVATE)

    fun getS(c: Context, k: String, def: String = ""): String = prefs(c).getString(k, null) ?: def
    fun setS(c: Context, k: String, v: String) { prefs(c).edit().putString(k, v).apply() }
    fun getD(c: Context, k: String, def: Double): Double = getS(c, k, "").replace(",", ".").trim().toDoubleOrNull() ?: def
    fun getB(c: Context, k: String, def: Boolean): Boolean = prefs(c).getBoolean(k, def)
    fun setB(c: Context, k: String, v: Boolean) { prefs(c).edit().putBoolean(k, v).apply() }

    private val dfDia = SimpleDateFormat("yyyy-MM-dd", Locale.US)
    fun today(): String = dfDia.format(Date())
    fun dia(ts: Long): String = dfDia.format(Date(ts))
    private fun hm(ts: Long): String = SimpleDateFormat("HH:mm", Locale.US).format(Date(ts))
    fun hora(ts: Long): String = hm(ts)
    private fun horaDe(ts: Long): Int { val cal = Calendar.getInstance(); cal.timeInMillis = ts; return cal.get(Calendar.HOUR_OF_DAY) }
    fun key(s: String): String = Normalizer.normalize(s.trim().lowercase(Locale.ROOT), Normalizer.Form.NFD)
        .replace(Regex("\\p{Mn}+"), "").replace(Regex("\\s+"), " ")

    // ---------- tiempo conectado a DiDi ----------
    private val onlineBuf = HashMap<String, Long>()
    private var lastMark = 0L
    private var lastFlush = 0L

    @Synchronized fun marcarConectado(c: Context, now: Long) {
        val dt = now - lastMark
        lastMark = now
        if (dt <= 0 || dt > 90000) return
        val k = dia(now) + "|" + horaDe(now)
        onlineBuf[k] = (onlineBuf[k] ?: 0L) + dt
        if (now - lastFlush > 60000) flushOnline(c)
    }

    @Synchronized fun flushOnline(c: Context) {
        lastFlush = System.currentTimeMillis()
        if (onlineBuf.isEmpty()) return
        val o = obj(c, "online.json")
        for ((k, v) in onlineBuf) {
            val d = k.substringBefore("|"); val hh = k.substringAfter("|")
            val dd = o.optJSONObject(d) ?: JSONObject()
            dd.put(hh, dd.optLong(hh, 0) + v / 1000)
            o.put(d, dd)
        }
        onlineBuf.clear()
        save(c, "online.json", o.toString())
    }

    fun horasConectado(c: Context, fecha: String): Double {
        flushOnline(c)
        val d = obj(c, "online.json").optJSONObject(fecha) ?: return 0.0
        var s = 0L
        for (k in d.keys()) s += d.optLong(k, 0)
        return s / 3600.0
    }

    // ---------- combustible: cargas ----------
    @Synchronized fun addCarga(c: Context, imp: Double, lit: Double, pre: Double) {
        val a = arr(c, "cargas.json")
        a.put(JSONObject().put("ts", System.currentTimeMillis()).put("imp", imp).put("lit", lit).put("pre", pre))
        save(c, "cargas.json", a.toString())
    }

    fun cargasResumen(c: Context): String {
        val a = arr(c, "cargas.json")
        if (a.length() == 0) return "Todavía no cargaste combustible."
        val sb = StringBuilder("Últimas cargas:")
        val f = SimpleDateFormat("dd/MM HH:mm", Locale.US)
        for (i in a.length() - 1 downTo maxOf(0, a.length() - 3)) {
            val o = a.getJSONObject(i)
            sb.append("\n").append(f.format(Date(o.getLong("ts")))).append(" · ")
                .append(Fmt.num(o.getDouble("lit"), 1)).append(" litros · ")
                .append(Fmt.money(o.getDouble("imp"))).append(" (")
                .append(Fmt.money(o.getDouble("pre"))).append(" el litro)")
        }
        return sb.toString()
    }

    fun precioLitro(c: Context): Double? {
        val a = arr(c, "cargas.json")
        return if (a.length() > 0) a.getJSONObject(a.length() - 1).getDouble("pre") else null
    }

    private fun litrosEntre(c: Context, t1: Long, t2: Long): Double {
        val a = arr(c, "cargas.json")
        var l = 0.0
        for (i in 0 until a.length()) { val o = a.getJSONObject(i); val ts = o.getLong("ts"); if (ts > t1 && ts <= t2) l += o.getDouble("lit") }
        return l
    }

    // ---------- tablero ----------
    private fun n16de(r: JSONObject): Int? = when {
        r.has("n16") -> r.getInt("n16")
        r.has("nivel") -> r.getInt("nivel") * 2
        else -> null
    }

    @Synchronized fun setTablero(c: Context, date: String, which: String, km: Long?, n16: Int?) {
        val o = obj(c, "tablero.json")
        val d = o.optJSONObject(date) ?: JSONObject()
        val r = JSONObject().put("ts", System.currentTimeMillis())
        if (km != null) r.put("km", km)
        if (n16 != null) r.put("n16", n16)
        d.put(which, r)
        o.put(date, d)
        save(c, "tablero.json", o.toString())
    }

    fun tableroHoy(c: Context, which: String): JSONObject? = obj(c, "tablero.json").optJSONObject(today())?.optJSONObject(which)

    private fun puntos(c: Context): List<Punto> {
        val t = obj(c, "tablero.json")
        val pts = ArrayList<Punto>()
        for (k in t.keys()) {
            val d = t.optJSONObject(k) ?: continue
            for (w in listOf("ini", "fin")) {
                val r = d.optJSONObject(w) ?: continue
                if (r.has("km")) pts.add(Punto(r.getLong("ts"), r.getLong("km"), n16de(r)))
            }
        }
        pts.sortBy { it.ts }
        return pts
    }

    /** Último kilometraje cargado (para "igual que el cierre de ayer"). */
    fun ultimoKm(c: Context): Long? = puntos(c).lastOrNull()?.km

    fun ultimoN16(c: Context): Int? = puntos(c).lastOrNull { it.n16 != null }?.n16

    fun tableroCorto(c: Context): String {
        val ini = tableroHoy(c, "ini") ?: return "Sin cargar hoy"
        val fin = tableroHoy(c, "fin") ?: return "Inicio " + hm(ini.getLong("ts")) + " · fin pendiente"
        return hm(ini.getLong("ts")) + " a " + hm(fin.getLong("ts"))
    }

    fun kmHoy(c: Context): Long? {
        val ini = tableroHoy(c, "ini") ?: return null
        val fin = tableroHoy(c, "fin") ?: return null
        if (!ini.has("km") || !fin.has("km")) return null
        return fin.getLong("km") - ini.getLong("km")
    }

    // ---------- consumo que aprende solo ----------
    fun aprendizaje(c: Context): Aprendizaje {
        val pts = puntos(c)
        var sxx = 0.0; var sxy = 0.0; var syy = 0.0; var sxl = 0.0; var syl = 0.0
        var n = 0
        for (i in 0 until pts.size - 1) {
            val p1 = pts[i]; val p2 = pts[i + 1]
            val dk = (p2.km - p1.km).toDouble()
            if (dk <= 0 || dk > 2000) continue
            val n1 = p1.n16 ?: continue
            val n2 = p2.n16 ?: continue
            val dn = (n2 - n1) / 16.0
            val l = litrosEntre(c, p1.ts, p2.ts)
            sxx += dk * dk; sxy += dk * dn; syy += dn * dn; sxl += dk * l; syl += dn * l
            n++
        }
        if (n >= 3) {
            val det = sxx * syy - sxy * sxy
            if (Math.abs(det) > 1e-6) {
                val a = (sxl * syy - syl * sxy) / det
                val cap = (syl * sxx - sxl * sxy) / det
                if (a > 1.0 / 30 && a < 1.0 / 4 && cap in 20.0..120.0) return Aprendizaje(1 / a, cap, "real", n)
            }
        }
        if (pts.size >= 2) {
            val span = (pts.last().km - pts.first().km).toDouble()
            val l = litrosEntre(c, pts.first().ts, pts.last().ts)
            if (span >= 300 && l >= 10) {
                val kml = span / l
                if (kml in 4.0..30.0) return Aprendizaje(kml, null, "aproximado", n)
            }
        }
        val m = getD(c, "kml_manual", 0.0)
        if (m > 0) return Aprendizaje(m, null, "manual", n)
        return Aprendizaje(null, null, "aprendiendo", n)
    }

    fun costoKm(c: Context): Double? {
        val a = aprendizaje(c)
        val kml = a.kml ?: return null
        val pre = precioLitro(c) ?: return null
        return pre / kml
    }

    /** Estima cuánto combustible queda ahora y para cuántos km o viajes alcanza. */
    fun tanque(c: Context): Tanque {
        val a = aprendizaje(c)
        val kml = a.kml ?: return Tanque(null, null, null, null, true)
        val cap = a.cap ?: getD(c, "tanque", 0.0).let { if (it > 0) it else 45.0 }
        val aprox = a.cap == null
        val pt = puntos(c).lastOrNull { it.n16 != null } ?: return Tanque(null, null, null, null, aprox)
        var lit = cap * (pt.n16 ?: 0) / 16.0 + litrosEntre(c, pt.ts, System.currentTimeMillis())
        lit -= kmDesde(c, pt.ts) / kml
        lit = lit.coerceIn(0.0, cap)
        val aut = lit * kml
        val avg = promedioKmViaje(c)
        return Tanque(lit / cap * 16, lit, aut, if (avg > 0) (aut / avg).toInt() else null, aprox)
    }

    private fun kmPedido(o: JSONObject): Double = if (o.has("pk")) o.optDouble("pk", 0.0) + o.optDouble("tk", 0.0) else o.optDouble("km", 0.0)

    private fun kmDesde(c: Context, t0: Long): Double {
        var km = 0.0
        for (o in pedidos(c)) if (o.optBoolean("acc") && o.getLong("ts") > t0) km += kmPedido(o) * 1.25
        return km
    }

    private fun promedioKmViaje(c: Context): Double {
        val l = pedidos(c).filter { it.optBoolean("acc") }.takeLast(20)
        if (l.isEmpty()) return 8.0
        return l.sumOf { kmPedido(it) } / l.size * 1.25
    }

    // ---------- zonas aprendidas del historial ----------
    private fun bump(b: JSONObject, barrio: String) {
        val k = key(barrio)
        val o = b.optJSONObject(k) ?: JSONObject().put("n", barrio).put("c", 0)
        o.put("c", o.getInt("c") + 1)
        b.put(k, o)
    }

    @Synchronized fun learnLines(c: Context, lines: List<String>): Int {
        val z = obj(c, "zonas.json")
        val b = z.optJSONObject("b") ?: JSONObject()
        val s = z.optJSONObject("s") ?: JSONObject()
        var n = 0
        for (raw in lines) {
            val l = Parser.clean(raw)
            if (!Parser.isAddress(l)) continue
            val barrio = Parser.zonaOf(l) ?: continue
            val sig = key(l)
            if (s.has(sig)) continue
            s.put(sig, 1)
            bump(b, barrio)
            n++
        }
        if (n > 0) {
            z.put("b", b)
            z.put("s", s)
            save(c, "zonas.json", z.toString())
        }
        return n
    }

    @Synchronized fun addTrip(c: Context, origin: String?, dest: String?) {
        val z = obj(c, "zonas.json")
        val b = z.optJSONObject("b") ?: JSONObject()
        origin?.let { bump(b, it) }
        dest?.let { bump(b, it) }
        z.put("b", b)
        save(c, "zonas.json", z.toString())
    }

    fun familiarity(c: Context, barrio: String?): Double? {
        if (barrio == null) return null
        val b = obj(c, "zonas.json").optJSONObject("b") ?: return null
        var total = 0
        var max = 0
        for (k in b.keys()) {
            val n = b.getJSONObject(k).getInt("c")
            total += n
            if (n > max) max = n
        }
        if (total < 10 || max == 0) return null
        val n = b.optJSONObject(key(barrio))?.getInt("c") ?: 0
        return Math.sqrt(n.toDouble() / max)
    }

    /** Zona de destino: suma si es tuya o tiene buena demanda a esta hora; resta si dejás pasar los verdes que van ahí. */
    fun zonaFactor(c: Context, zona: String): Pair<Double, String> {
        val all = pedidos(c)
        val now = System.currentTimeMillis()
        val zk = key(zona)
        var gNot = 0
        var gTak = 0
        val banda = horaDe(now) / 3
        val cuenta = HashMap<String, Int>()
        for (o in all) {
            if (key(o.optString("d")) == zk) {
                if (o.optBoolean("acc")) gTak++ else if (o.optInt("lv", 0) >= 2 && now - o.getLong("ts") > 180000) gNot++
            }
            if (horaDe(o.getLong("ts")) / 3 == banda) { val oz = key(o.optString("o")); if (oz.isNotEmpty()) cuenta[oz] = (cuenta[oz] ?: 0) + 1 }
        }
        var delta = 0.0
        val motivos = ArrayList<String>()
        val fam = familiarity(c, zona)
        if (fam != null && fam >= 0.3) { delta += 0.05 * fam; motivos.add(if (fam >= 0.6) "zona tuya" else "zona conocida") }
        if (gNot + gTak >= 3) {
            val pen = 0.20 * gNot / (gNot + gTak)
            if (pen >= 0.04) { delta -= pen; motivos.add("no solés ir") }
        }
        val cz = cuenta[zk] ?: 0
        val mx = cuenta.values.maxOrNull() ?: 0
        if (cz >= 5 && mx > 0) {
            val b = 0.05 * cz / mx
            delta += b
            if (b >= 0.025) motivos.add("buena demanda a esta hora")
        }
        return Pair(delta, motivos.joinToString(" · "))
    }

    fun zonasResumen(c: Context): String {
        val b = obj(c, "zonas.json").optJSONObject("b") ?: return "Todavía no aprendí tus zonas."
        val l = ArrayList<Pair<String, Int>>()
        for (k in b.keys()) {
            val o = b.getJSONObject(k)
            l.add(Pair(o.getString("n"), o.getInt("c")))
        }
        if (l.isEmpty()) return "Todavía no aprendí tus zonas."
        l.sortByDescending { it.second }
        var total = 0
        for (x in l) total += x.second
        val max = l[0].second
        val sb = StringBuilder("Aprendí " + total + " paradas en " + l.size + " zonas. Las más tuyas:")
        for (x in l.take(12)) {
            val bars = "█".repeat(maxOf(1, (8.0 * x.second / max).toInt()))
            sb.append("\n").append(bars).append(" ").append(x.first).append(" (").append(x.second).append(")")
        }
        return sb.toString()
    }

    fun clearZonas(c: Context) { file(c, "zonas.json").delete() }

    // ---------- pantallas guardadas (para ajustar la lectura) ----------
    @Synchronized fun saveSnap(c: Context, lines: List<String>, ok: Boolean) {
        val a = arr(c, "pantallas.json")
        val h = lines.joinToString("|").hashCode()
        if (a.length() > 0 && a.getJSONObject(a.length() - 1).optInt("h") == h) return
        val t = JSONArray()
        for (l in lines.take(150)) t.put(l)
        a.put(JSONObject().put("ts", System.currentTimeMillis()).put("h", h).put("ok", ok).put("t", t))
        val out = JSONArray()
        for (i in maxOf(0, a.length() - 8) until a.length()) out.put(a.get(i))
        save(c, "pantallas.json", out.toString())
    }

    fun snapsTexto(c: Context): String {
        val a = arr(c, "pantallas.json")
        if (a.length() == 0) return "(ninguna todavía)"
        val sb = StringBuilder()
        for (i in a.length() - 1 downTo 0) {
            val o = a.getJSONObject(i)
            sb.append("--- ").append(hm(o.getLong("ts"))).append(if (o.optBoolean("ok")) " (pedido reconocido)" else " (no reconocido)").append(" ---\n")
            val t = o.getJSONArray("t")
            for (j in 0 until t.length()) sb.append(t.getString(j)).append("\n")
        }
        return sb.toString()
    }

    // ---------- pedidos ----------
    private fun fin(v: Double): Double = if (v.isNaN() || v.isInfinite()) 0.0 else v
    private var pedCache: List<JSONObject>? = null
    private var pedMod = 0L

    @Synchronized fun pedidos(c: Context): List<JSONObject> {
        val f = file(c, "pedidos.json")
        val m = f.lastModified()
        val cached = pedCache
        if (cached != null && m == pedMod) return cached
        val a = arr(c, "pedidos.json")
        val l = ArrayList<JSONObject>()
        for (i in 0 until a.length()) l.add(a.getJSONObject(i))
        pedCache = l
        pedMod = m
        return l
    }

    @Synchronized private fun guardarPedidos(c: Context, l: List<JSONObject>) {
        val out = JSONArray()
        for (o in l.takeLast(3000)) out.put(o)
        save(c, "pedidos.json", out.toString())
        pedCache = null
    }

    @Synchronized fun logPedido(c: Context, p: Pedido, e: Eval): Long {
        val ts = System.currentTimeMillis()
        val l = ArrayList(pedidos(c))
        l.add(
            JSONObject().put("ts", ts).put("price", p.price)
                .put("km", fin(p.pKm + p.tKm)).put("min", p.pMin + p.tMin)
                .put("pk", fin(p.pKm)).put("tk", fin(p.tKm)).put("pm", p.pMin)
                .put("o", p.origin ?: "").put("d", p.dest ?: "").put("v", e.label)
                .put("pkm", fin(e.perKm)).put("ph", fin(e.perHour)).put("acc", false)
                .put("pct", e.pct).put("lv", e.level).put("ef", p.efectivo).put("ptp", p.ptp)
        )
        guardarPedidos(c, l)
        return ts
    }

    @Synchronized fun actualizarEval(c: Context, ts: Long, e: Eval) {
        val l = pedidos(c)
        val o = l.lastOrNull { it.getLong("ts") == ts } ?: return
        o.put("pct", e.pct).put("lv", e.level).put("v", e.label)
        guardarPedidos(c, l)
    }

    /** Marca un pedido como tomado o no (detectado o corregido a mano). */
    @Synchronized fun setTomado(c: Context, ts: Long, acc: Boolean) {
        val l = pedidos(c)
        val o = l.lastOrNull { it.getLong("ts") == ts } ?: return
        if (o.optBoolean("acc") == acc) return
        o.put("acc", acc)
        guardarPedidos(c, l)
        if (acc) addTrip(c, o.optString("o").ifEmpty { null }, o.optString("d").ifEmpty { null })
    }

    fun ultimosPedidos(c: Context, n: Int): List<JSONObject> = pedidos(c).takeLast(n).reversed()

    // ---------- informe ----------
    private fun lunesDe(ts: Long): String {
        val cal = Calendar.getInstance()
        cal.timeInMillis = ts
        cal.firstDayOfWeek = Calendar.MONDAY
        cal.set(Calendar.DAY_OF_WEEK, Calendar.MONDAY)
        return dfDia.format(cal.time)
    }

    /** Lo que DiDi dice que ganaste la semana pasada: sirve para sacar la comisión real. */
    @Synchronized fun guardarPagoSemana(c: Context, monto: Double) {
        val o = obj(c, "pagos.json")
        o.put(lunesDe(System.currentTimeMillis() - 7L * 86400000), monto)
        save(c, "pagos.json", o.toString())
    }

    fun comisionTasa(c: Context): Pair<Double, Boolean> {
        val pg = obj(c, "pagos.json")
        val tasas = ArrayList<Double>()
        for (sem in pg.keys()) {
            val monto = pg.optDouble(sem, 0.0)
            val cobrado = pedidos(c).filter { it.optBoolean("acc") && lunesDe(it.getLong("ts")) == sem }.sumOf { it.optDouble("price", 0.0) }
            if (cobrado > 0 && monto > 0) {
                val t = 1 - monto / cobrado
                if (t in 0.0..0.6) tasas.add(t)
            }
        }
        return if (tasas.isEmpty()) Pair(0.25, false) else Pair(tasas.average(), true)
    }

    fun informe(c: Context, dias: Int): List<Dia> {
        val out = ArrayList<Dia>()
        val tasa = comisionTasa(c).first
        val ck = costoKm(c)
        val all = pedidos(c)
        val tab = obj(c, "tablero.json")
        for (i in dias - 1 downTo 0) {
            val f = dia(System.currentTimeMillis() - i * 86400000L)
            val tom = all.filter { it.optBoolean("acc") && dia(it.getLong("ts")) == f }
            val cobrado = tom.sumOf { it.optDouble("price", 0.0) }
            var km = tom.sumOf { kmPedido(it) } * 1.25
            val d = tab.optJSONObject(f)
            val ini = d?.optJSONObject("ini")
            val fn = d?.optJSONObject("fin")
            if (ini != null && fn != null && ini.has("km") && fn.has("km")) km = (fn.getLong("km") - ini.getLong("km")).toDouble()
            val comb = if (ck != null) km * ck else null
            val com = cobrado * tasa
            out.add(Dia(f, horasConectado(c, f), tom.size, cobrado, km, comb, com, cobrado - com - (comb ?: 0.0)))
        }
        return out
    }

    /** Franjas de 3 horas: cuántos pedidos entran y cuánto pagan por hora en promedio. */
    fun franjas(c: Context): List<Franja> {
        val on = obj(c, "online.json")
        val horas = DoubleArray(8)
        for (d in on.keys()) { val dd = on.optJSONObject(d) ?: continue; for (hh in dd.keys()) { val h = hh.toIntOrNull() ?: continue; horas[h / 3] += dd.optLong(hh, 0) / 3600.0 } }
        val n = IntArray(8)
        val ph = DoubleArray(8)
        for (o in pedidos(c)) { val b = horaDe(o.getLong("ts")) / 3; n[b]++; ph[b] += o.optDouble("ph", 0.0) }
        val out = ArrayList<Franja>()
        for (b in 0 until 8) if (n[b] >= 5) out.add(Franja(b * 3, n[b], ph[b] / n[b], if (horas[b] >= 1) n[b] / horas[b] else null))
        return out.sortedByDescending { it.porHora }
    }
}
EOF_ALVOLANTE
mkdir -p "proj/app/src/main/java/com/pablo/alvolante"
cat > 'proj/app/src/main/java/com/pablo/alvolante/Vistas.kt' <<'EOF_ALVOLANTE'
package com.pablo.alvolante

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View

/** Medidor de combustible de 16 posiciones: marcas grandes en ¼, chicas en octavos y saltito sin dibujar en el medio. */
class Medidor(c: Context) : View(c) {
    var nivel = 8
        set(v) { field = v.coerceIn(0, 16); invalidate(); onCambio?.invoke(field) }
    var onCambio: ((Int) -> Unit)? = null
    private val d = resources.displayMetrics.density
    private val pFondo = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pRelleno = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pMarca = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pTexto = Paint(Paint.ANTI_ALIAS_FLAG)

    init {
        pFondo.color = Color.argb(0x33, 0x88, 0x87, 0x80)
        pMarca.color = Color.argb(0xAA, 0x44, 0x44, 0x41)
        pTexto.color = Color.rgb(0x88, 0x87, 0x80)
        pTexto.textSize = 13 * d
        pTexto.textAlign = Paint.Align.CENTER
        minimumHeight = (78 * d).toInt()
    }

    override fun onMeasure(w: Int, h: Int) {
        setMeasuredDimension(MeasureSpec.getSize(w), (78 * d).toInt())
    }

    override fun onDraw(cv: Canvas) {
        val pad = 14 * d
        val w = width - 2 * pad
        val top = 8 * d
        val alto = 30 * d
        val r = RectF(pad, top, pad + w, top + alto)
        cv.drawRoundRect(r, alto / 2, alto / 2, pFondo)
        pRelleno.color = when {
            nivel <= 2 -> Color.rgb(0xE2, 0x4B, 0x4A)
            nivel <= 4 -> Color.rgb(0xBA, 0x75, 0x17)
            else -> Color.rgb(0x63, 0x99, 0x22)
        }
        if (nivel > 0) cv.drawRoundRect(RectF(pad, top, pad + w * nivel / 16f, top + alto), alto / 2, alto / 2, pRelleno)
        val et = arrayOf("V", "¼", "½", "¾", "Ll")
        for (i in 0..16) {
            if (i % 2 == 1) continue
            val x = pad + w * i / 16f
            val grande = i % 4 == 0
            pMarca.strokeWidth = (if (grande) 2.5f else 1.5f) * d
            cv.drawLine(x, top + alto + 2 * d, x, top + alto + (if (grande) 12 else 7) * d, pMarca)
            if (grande) cv.drawText(et[i / 4], x, top + alto + 27 * d, pTexto)
        }
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        val pad = 14 * d
        val w = width - 2 * pad
        nivel = Math.round((e.x - pad) / w * 16)
        parent?.requestDisallowInterceptTouchEvent(true)
        return true
    }
}

/** Barras simples para el informe. */
class Barras(c: Context, private val valores: DoubleArray, private val etiquetas: Array<String>) : View(c) {
    private val d = resources.displayMetrics.density
    private val p = Paint(Paint.ANTI_ALIAS_FLAG)
    private val t = Paint(Paint.ANTI_ALIAS_FLAG)

    override fun onMeasure(w: Int, h: Int) {
        setMeasuredDimension(MeasureSpec.getSize(w), (170 * d).toInt())
    }

    override fun onDraw(cv: Canvas) {
        val n = valores.size
        if (n == 0) return
        val max = maxOf(1.0, valores.maxOrNull() ?: 1.0)
        val abajo = height - 22 * d
        val ancho = width.toFloat() / n
        t.color = Color.rgb(0x88, 0x87, 0x80)
        t.textSize = 12 * d
        t.textAlign = Paint.Align.CENTER
        for (i in 0 until n) {
            val v = valores[i]
            val alto = (abajo - 18 * d) * (maxOf(0.0, v) / max).toFloat()
            p.color = if (v > 0) Color.rgb(0x3B, 0x6D, 0x11) else Color.rgb(0xE2, 0x4B, 0x4A)
            val x0 = i * ancho + ancho * 0.18f
            val x1 = (i + 1) * ancho - ancho * 0.18f
            cv.drawRoundRect(RectF(x0, abajo - maxOf(alto, 2 * d), x1, abajo), 4 * d, 4 * d, p)
            cv.drawText(etiquetas[i], (x0 + x1) / 2, height - 6 * d, t)
            if (v != 0.0) cv.drawText(if (Math.abs(v) >= 1000) Fmt.num(v / 1000, 0) + "k" else Fmt.num(v, 0), (x0 + x1) / 2, abajo - alto - 4 * d, t)
        }
    }
}
EOF_ALVOLANTE
mkdir -p "proj/app/src/main/java/com/pablo/alvolante"
cat > 'proj/app/src/main/java/com/pablo/alvolante/Zonas.kt' <<'EOF_ALVOLANTE'
package com.pablo.alvolante

import android.content.Context
import android.location.Geocoder
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Locale

internal class Poli(val nombre: String, val minX: Double, val minY: Double, val maxX: Double, val maxY: Double, val p: DoubleArray)

/** Zonas peligrosas: polígonos oficiales de barrios populares (Ciudad y Provincia) guardados dentro de la app. */
object Zonas {
    @Volatile private var polis: List<Poli>? = null
    @Volatile private var cargando = false
    private val h = Handler(Looper.getMainLooper())

    fun cantidad(): Int = polis?.size ?: -1

    fun cargar(c: Context) {
        if (polis != null || cargando) return
        cargando = true
        Thread {
            val out = ArrayList<Poli>()
            try {
                val txt = c.assets.open("zonas.json").bufferedReader().use { it.readText() }
                val a = JSONArray(txt)
                for (i in 0 until a.length()) {
                    val o = a.getJSONObject(i)
                    val b = o.getJSONArray("b")
                    val pa = o.getJSONArray("p")
                    val d = DoubleArray(pa.length())
                    for (j in 0 until pa.length()) d[j] = pa.getDouble(j)
                    out.add(Poli(o.optString("n", "Barrio popular"), b.getDouble(0), b.getDouble(1), b.getDouble(2), b.getDouble(3), d))
                }
            } catch (e: Exception) { }
            polis = out
            cargando = false
        }.start()
    }

    private fun dentro(x: Double, y: Double, p: DoubleArray): Boolean {
        var inside = false
        val n = p.size / 2
        var j = n - 1
        for (i in 0 until n) {
            val xi = p[2 * i]; val yi = p[2 * i + 1]; val xj = p[2 * j]; val yj = p[2 * j + 1]
            if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside
            j = i
        }
        return inside
    }

    /** Distancia aproximada en metros del punto al borde del polígono. */
    private fun distBorde(x: Double, y: Double, p: DoubleArray): Double {
        val kx = 111320.0 * Math.cos(Math.toRadians(y))
        val ky = 110540.0
        var best = Double.MAX_VALUE
        val n = p.size / 2
        for (i in 0 until n) {
            val j = (i + 1) % n
            val ax = (p[2 * i] - x) * kx; val ay = (p[2 * i + 1] - y) * ky
            val bx = (p[2 * j] - x) * kx; val by = (p[2 * j + 1] - y) * ky
            val dx = bx - ax; val dy = by - ay
            val len = dx * dx + dy * dy
            var t = if (len > 0) -(ax * dx + ay * dy) / len else 0.0
            t = t.coerceIn(0.0, 1.0)
            val px = ax + t * dx; val py = ay + t * dy
            val d = Math.sqrt(px * px + py * py)
            if (d < best) best = d
        }
        return best
    }

    /** Devuelve (nombre del barrio si cae adentro, true si está a menos de 150 m). */
    fun chequear(lat: Double, lon: Double): Pair<String?, Boolean> {
        val ps = polis ?: return Pair(null, false)
        var cerca = false
        val m = 0.0016
        for (p in ps) {
            if (lon < p.minX - m || lon > p.maxX + m || lat < p.minY - m || lat > p.maxY + m) continue
            if (dentro(lon, lat, p.p)) return Pair(p.nombre, true)
            if (!cerca && distBorde(lon, lat, p.p) < 150) cerca = true
        }
        return Pair(null, cerca)
    }

    // ---------- ubicar direcciones (con caché) ----------
    private fun cacheFile(c: Context) = File(c.filesDir, "geo.json")
    @Synchronized private fun cacheGet(c: Context, k: String): String? = try { JSONObject(cacheFile(c).readText()).optString(k, "").ifEmpty { null } } catch (e: Exception) { null }
    @Synchronized private fun cachePut(c: Context, k: String, v: String) {
        val o = try { JSONObject(cacheFile(c).readText()) } catch (e: Exception) { JSONObject() }
        if (o.length() > 3000) return
        o.put(k, v)
        try { cacheFile(c).writeText(o.toString()) } catch (e: Exception) { }
    }

    @Suppress("DEPRECATION")
    private fun ubicar(c: Context, q: String): DoubleArray? {
        val k = Store.key(q)
        val cached = cacheGet(c, k)
        if (cached != null) {
            if (cached == "x") return null
            val parts = cached.split(",")
            return doubleArrayOf(parts[0].toDouble(), parts[1].toDouble())
        }
        return try {
            val r = Geocoder(c, Locale.forLanguageTag("es-AR")).getFromLocationName(q, 1)
            if (r != null && r.isNotEmpty()) {
                cachePut(c, k, r[0].latitude.toString() + "," + r[0].longitude)
                doubleArrayOf(r[0].latitude, r[0].longitude)
            } else { cachePut(c, k, "x"); null }
        } catch (e: Exception) { null }
    }

    /** Chequea origen y destino en segundo plano y avisa por cb en el hilo principal. */
    fun evaluar(c: Context, p: Pedido, cb: (Riesgo) -> Unit) {
        cargar(c)
        if (!Geocoder.isPresent()) { cb(Riesgo(false, null, null, false, true)); return }
        Thread {
            var o: String? = null
            var d: String? = null
            var cerca = false
            var sinUbicar = false
            for (i in 0..1) {
                val q = Parser.geoQuery(if (i == 0) p.originAddr else p.destAddr)
                if (q == null) { if (i == 1) sinUbicar = true; continue }
                val ll = ubicar(c, q)
                if (ll == null) { if (i == 1) sinUbicar = true; continue }
                var tries = 0
                while (polis == null && tries < 30) { Thread.sleep(100); tries++ }
                val res = chequear(ll[0], ll[1])
                if (res.first != null) { if (i == 0) o = res.first else d = res.first } else if (res.second) cerca = true
            }
            val r = Riesgo(false, o, d, cerca, sinUbicar && o == null && d == null)
            h.post { cb(r) }
        }.start()
    }
}
EOF_ALVOLANTE
mkdir -p "proj/app/src/main/res/drawable"
cat > 'proj/app/src/main/res/drawable/ic_launcher.xml' <<'EOF_ALVOLANTE'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <path android:fillColor="#1B1E22" android:pathData="M0,0h108v108h-108z" />
    <path android:fillColor="#2B2F35" android:pathData="M40,12h28a8,8 0 0 1 8,8v68a8,8 0 0 1 -8,8h-28a8,8 0 0 1 -8,-8v-68a8,8 0 0 1 8,-8z" />
    <path android:fillColor="#E0392B" android:pathData="M44,32a10,10 0 1,0 20,0a10,10 0 1,0 -20,0z" />
    <path android:fillColor="#F2C200" android:pathData="M44,54a10,10 0 1,0 20,0a10,10 0 1,0 -20,0z" />
    <path android:fillColor="#1F9D55" android:pathData="M44,76a10,10 0 1,0 20,0a10,10 0 1,0 -20,0z" />
</vector>
EOF_ALVOLANTE
mkdir -p "proj/app/src/main/res/values"
cat > 'proj/app/src/main/res/values/strings.xml' <<'EOF_ALVOLANTE'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="a11y_label">Al volante: semáforo de DiDi</string>
    <string name="a11y_desc">Lee el precio, los minutos y los km de los pedidos de DiDi para mostrarte un semáforo arriba de la pantalla. Solo lee: no toca, no acepta ni rechaza nada.</string>
</resources>
EOF_ALVOLANTE
mkdir -p "proj/app/src/main/res/xml"
cat > 'proj/app/src/main/res/xml/accessibility_config.xml' <<'EOF_ALVOLANTE'
<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeWindowStateChanged|typeWindowContentChanged|typeWindowsChanged"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:accessibilityFlags="flagRetrieveInteractiveWindows|flagIncludeNotImportantViews|flagReportViewIds"
    android:canRetrieveWindowContent="true"
    android:canTakeScreenshot="true"
    android:notificationTimeout="250"
    android:description="@string/a11y_desc" />
EOF_ALVOLANTE
echo "Proyecto generado"
