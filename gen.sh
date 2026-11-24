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
        versionCode = 3
        versionName = "1.2"
        ndk { abiFilters += listOf("arm64-v8a") }
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
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Handler
import android.os.Looper
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
    }

    private val h = Handler(Looper.getMainLooper())
    private var overlay: Overlay? = null
    private var scheduled = false
    private var lastSeenReq = 0L
    private var currentSig: String? = null
    private var pending: Pedido? = null
    private var pendingTs = 0L

    private val scanR = Runnable { scheduled = false; scan() }
    private val tick = object : Runnable {
        override fun run() {
            if (currentSig != null) {
                if (System.currentTimeMillis() - lastSeenReq > 1200) scan()
                if (currentSig != null && System.currentTimeMillis() - lastSeenReq > 3000) {
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
        h.post(tick)
    }

    override fun onDestroy() {
        instance = null
        overlay?.hide()
        h.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun onInterrupt() {}

    private fun isDidi(p: String): Boolean {
        val l = p.lowercase()
        return l.contains("didi") || l.contains("xiaojukeji")
    }

    override fun onAccessibilityEvent(e: AccessibilityEvent?) {
        val pkg = e?.packageName?.toString() ?: return
        if (pkg == packageName) return
        synchronized(seenPkgs) { if (seenPkgs.size < 40) seenPkgs.add(pkg) }
        if (!isDidi(pkg)) return
        if (!scheduled) {
            scheduled = true
            h.postDelayed(scanR, 300)
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
        try {
            for (w in windows) {
                val r = w.root ?: continue
                if (isDidi(r.packageName?.toString() ?: "")) collect(r, lines, 0)
            }
        } catch (e: Exception) { }
        if (lines.isEmpty()) {
            try {
                val r = rootInActiveWindow
                if (r != null && isDidi(r.packageName?.toString() ?: "")) collect(r, lines, 0)
            } catch (e: Exception) { }
        }
        if (lines.isEmpty()) return
        lastLines = lines
        if (Store.getB(this, "aprender", false)) Store.learnLines(this, lines)

        val now = System.currentTimeMillis()
        val p = Parser.parse(lines)
        if (lines.any { Parser.minRx.containsMatchIn(it) }) Store.saveSnap(this, lines, p != null)
        if (p != null) {
            lastSeenReq = now
            val sig = p.price.toString() + "|" + p.tKm + "|" + (p.destAddr ?: "")
            if (sig != currentSig) {
                currentSig = sig
                val ev = Evaluator.eval(this, p)
                overlay?.show(ev, p)
                Store.logPedido(this, p, ev)
                pending = p
                pendingTs = now
            }
            return
        }
        // ¿Lo tomó? Si después del pedido aparece la dirección de búsqueda en otra pantalla de DiDi.
        val pd = pending ?: return
        if (now - pendingTs > 180000) { pending = null; return }
        val street = (pd.originAddr ?: pd.destAddr)?.substringBefore(",")?.trim()
        if (street != null && street.length >= 5 && lines.any { it.contains(street) }) {
            Store.addTrip(this, pd)
            Store.markLastAccepted(this)
            pending = null
        }
    }

    fun test() {
        val p = Pedido(9900.0, "1,2", 3, 0.316, 29, 8.1, "Balvanera", "Puerto Madero",
            "Tucumán 3231, CABA - Balvanera", "Violeta Parra 1677, CABA - Puerto Madero")
        overlay?.show(Evaluator.eval(this, p), p)
        h.postDelayed({ if (currentSig == null) overlay?.hide() }, 8000)
    }
}

class Overlay(private val ctx: Context) {
    private val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private var view: View? = null
    private val h = Handler(Looper.getMainLooper())
    private val hideR = Runnable { hide() }

    private fun dp(v: Double): Int = (v * ctx.resources.displayMetrics.density).toInt()

    fun show(e: Eval, p: Pedido) {
        hide()
        val box = LinearLayout(ctx)
        box.orientation = LinearLayout.VERTICAL
        box.setPadding(dp(18.0), dp(12.0), dp(18.0), dp(14.0))
        val bg = GradientDrawable()
        bg.setColor(e.color)
        bg.cornerRadius = dp(20.0).toFloat()
        box.background = bg
        box.elevation = dp(8.0).toFloat()

        fun line(t: String, size: Float, bold: Boolean) {
            if (t.isEmpty()) return
            val tv = TextView(ctx)
            tv.text = t
            tv.textSize = size
            tv.setTextColor(e.textColor)
            if (bold) tv.typeface = Typeface.DEFAULT_BOLD
            box.addView(tv)
        }
        line(e.label + " · " + Fmt.money(p.price) + (if (p.mult != null) "  ⚡" + p.mult + "x" else ""), 26f, true)
        line(Fmt.money(e.perKm) + " por km · " + Fmt.money(e.perHour) + " por hora", 18f, true)
        line(Fmt.num(p.pKm + p.tKm, 1) + " km y " + (p.pMin + p.tMin) + " min en total (" + p.pMin + " min para buscarlo)", 15f, false)
        line(e.zona, 15f, false)
        val f = e.fuel
        if (f != null) line("Combustible del viaje: " + Fmt.money(f) + " · te quedan " + Fmt.money(p.price - f), 15f, false)

        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        )
        lp.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
        lp.y = dp(Store.getD(ctx, "overlay_y", 90.0))
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
    fun read(c: Context, uri: Uri, cb: (String?) -> Unit) {
        try {
            val img = InputImage.fromFilePath(c, uri)
            TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS).process(img)
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
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.provider.MediaStore
import android.provider.Settings
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast

class MainActivity : Activity() {
    private lateinit var root: LinearLayout
    private var camUri: Uri? = null
    private var camFin = false
    private lateinit var tvEstado: TextView
    private lateinit var tvTablero: TextView
    private lateinit var tvConsumo: TextView
    private lateinit var tvCargas: TextView
    private lateinit var tvZonas: TextView
    private lateinit var tvPedidos: TextView

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()
    private fun toast(s: String) { Toast.makeText(this, s, Toast.LENGTH_LONG).show() }

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        val saved = b?.getString("camUri")
        if (saved != null) camUri = Uri.parse(saved)
        camFin = b?.getBoolean("camFin") ?: false
        val sv = ScrollView(this)
        root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setPadding(dp(18), dp(18), dp(18), dp(48))
        sv.addView(root)
        setContentView(sv)
        build()
    }

    override fun onSaveInstanceState(o: Bundle) {
        super.onSaveInstanceState(o)
        val u = camUri
        if (u != null) o.putString("camUri", u.toString())
        o.putBoolean("camFin", camFin)
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    // ---------- piezas de pantalla ----------
    private fun tv(t: String, size: Float, bold: Boolean, top: Int): TextView {
        val v = TextView(this)
        v.text = t
        v.textSize = size
        if (bold) v.setTypeface(v.typeface, Typeface.BOLD)
        v.setPadding(0, dp(top), 0, dp(4))
        root.addView(v)
        return v
    }
    private fun h1(t: String) = tv(t, 30f, true, 0)
    private fun h2(t: String) = tv(t, 22f, true, 26)
    private fun p(t: String = "") = tv(t, 16f, false, 4)

    private fun btn(t: String, f: () -> Unit): Button {
        val b = Button(this)
        b.text = t
        b.isAllCaps = false
        b.textSize = 17f
        b.setOnClickListener { f() }
        root.addView(b)
        return b
    }

    private fun numEdit(label: String, decimal: Boolean = true): EditText {
        p(label)
        val e = EditText(this)
        e.inputType = InputType.TYPE_CLASS_NUMBER or (if (decimal) InputType.TYPE_NUMBER_FLAG_DECIMAL else 0)
        e.textSize = 18f
        root.addView(e)
        return e
    }

    private fun field(label: String, key: String, def: String, decimal: Boolean = true): EditText {
        val e = numEdit(label, decimal)
        e.setText(Store.getS(this, key, def))
        e.addTextChangedListener(object : TextWatcher {
            override fun afterTextChanged(s: Editable?) { Store.setS(this@MainActivity, key, s?.toString() ?: ""); refreshLight() }
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
        })
        return e
    }

    private fun num(e: EditText): Double? = e.text.toString().replace(",", ".").trim().toDoubleOrNull()

    // ---------- pantalla ----------
    private fun build() {
        h1("Al volante")
        tvEstado = p()
        btn("Activar lectura de DiDi") { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
        p("Si Android no te deja activarla: tocá \"Abrir info de la app\", después los tres puntitos de arriba a la derecha y \"Permitir ajustes restringidos\". Después volvé a activarla.")
        btn("Abrir info de la app") {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + packageName)))
        }
        btn("Probar el semáforo") {
            val s = DidiReaderService.instance
            if (s == null) toast("Primero activá la lectura de DiDi.") else { s.test(); toast("Mirá arriba de la pantalla.") }
        }

        h2("Tu vara")
        p("El semáforo compara cada pedido con lo que querés ganar. Cuenta el viaje completo: lo que tardás y recorrés para buscarlo más el viaje.")
        field("Querés ganar por km (\$)", "obj_km", "1000")
        field("Querés ganar por hora (\$)", "obj_h", "15000")
        field("Cuánto pesa la zona de destino (%)", "zona_peso", "15")
        field("Amarillo desde (% de tu meta)", "amarillo", "85")
        field("Altura de la burbuja desde arriba", "overlay_y", "90", false)

        h2("Tablero")
        p("Sacale una foto al tablero al empezar y al terminar. Leo el kilometraje solo; vos solo confirmás.")
        tvTablero = p()
        btn("Foto del tablero al empezar") { foto(false) }
        btn("Foto del tablero al terminar") { foto(true) }

        h2("Combustible")
        p("Cada vez que cargás, poné dos de estos tres datos y calculo el tercero.")
        val eImp = numEdit("Importe pagado (\$)")
        val eLit = numEdit("Litros cargados")
        val ePre = numEdit("Precio por litro (\$)")
        btn("Guardar carga") { guardarCarga(eImp, eLit, ePre) }
        tvCargas = p()
        tvConsumo = p()
        field("Capacidad del tanque en litros (opcional, mejora la cuenta)", "tanque", "")
        field("Consumo mientras junto datos (km por litro)", "kml_manual", "")

        h2("Tus zonas")
        p("Con tus viajes anteriores el semáforo suma verde si el destino es una zona donde solés andar y resta si es una zona rara para vos. Para enseñarme: prendé \"Modo aprender\", abrí el historial de viajes en DiDi y bajá despacio. Apagalo cuando termines. También podés elegir capturas del historial.")
        val sw = Switch(this)
        sw.text = "Modo aprender"
        sw.textSize = 18f
        sw.isChecked = Store.getB(this, "aprender", false)
        sw.setOnCheckedChangeListener { _, on -> Store.setB(this, "aprender", on); refresh() }
        root.addView(sw)
        btn("Leer capturas del historial") {
            val i = Intent(Intent.ACTION_OPEN_DOCUMENT)
            i.addCategory(Intent.CATEGORY_OPENABLE)
            i.type = "image/*"
            i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            startActivityForResult(i, 3)
        }
        tvZonas = p()
        btn("Borrar zonas aprendidas") {
            AlertDialog.Builder(this).setMessage("¿Borrar todas las zonas aprendidas?")
                .setPositiveButton("Borrar") { _, _ -> Store.clearZonas(this); refresh() }
                .setNegativeButton("Cancelar", null).show()
        }

        h2("Últimos pedidos")
        tvPedidos = p()
        btn("Ver lo que leo de DiDi") { verLeido() }
    }

    private fun isServiceOn(): Boolean {
        val s = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        return s.contains(packageName + "/")
    }

    private fun refreshLight() {
        if (::tvConsumo.isInitialized) tvConsumo.text = Store.consumoResumen(this)
    }

    private fun refresh() {
        if (!::tvEstado.isInitialized) return
        tvEstado.text = if (isServiceOn()) "Lectura de DiDi: ACTIVA. Cuando entre un pedido aparece el semáforo arriba de la pantalla."
        else "Lectura de DiDi: APAGADA. Activala para ver el semáforo."
        tvTablero.text = Store.tableroResumen(this)
        tvCargas.text = Store.cargasResumen(this)
        tvConsumo.text = Store.consumoResumen(this)
        tvZonas.text = (if (Store.getB(this, "aprender", false)) "Modo aprender PRENDIDO: abrí el historial en DiDi y bajá.\n\n" else "") + Store.zonasResumen(this)
        tvPedidos.text = Store.pedidosResumen(this)
    }

    // ---------- combustible ----------
    private fun guardarCarga(eImp: EditText, eLit: EditText, ePre: EditText) {
        var imp = num(eImp)
        var lit = num(eLit)
        var pre = num(ePre)
        if (imp == null && lit != null && pre != null) imp = lit * pre
        if (lit == null && imp != null && pre != null && pre > 0) lit = imp / pre
        if (pre == null && imp != null && lit != null && lit > 0) pre = imp / lit
        if (imp == null || lit == null || pre == null || imp <= 0 || lit <= 0) { toast("Completá dos de los tres datos."); return }
        Store.addCarga(this, imp, lit, pre)
        eImp.setText(""); eLit.setText(""); ePre.setText("")
        toast("Carga guardada: " + Fmt.num(lit, 1) + " litros a " + Fmt.money(pre) + " el litro.")
        refresh()
    }

    // ---------- tablero ----------
    private fun foto(fin: Boolean) {
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
            Ocr.read(this, u) { txt -> confirmarTablero(Ocr.odometer(txt ?: "", Store.lastOdo(this)), fin) }
        }
        if (req == 3 && res == RESULT_OK && data != null) {
            val uris = ArrayList<Uri>()
            val cd = data.clipData
            if (cd != null) { for (i in 0 until cd.itemCount) uris.add(cd.getItemAt(i).uri) }
            else { val d = data.data; if (d != null) uris.add(d) }
            if (uris.isNotEmpty()) leerCapturas(uris)
        }
    }

    private fun confirmarTablero(km: Long?, fin: Boolean) {
        val box = LinearLayout(this)
        box.orientation = LinearLayout.VERTICAL
        box.setPadding(dp(22), dp(8), dp(22), 0)
        val t1 = TextView(this)
        t1.text = if (km != null) "Leí este kilometraje. Si está mal, corregilo:" else "No pude leer el kilometraje. Escribilo:"
        t1.textSize = 16f
        box.addView(t1)
        val e = EditText(this)
        e.inputType = InputType.TYPE_CLASS_NUMBER
        e.textSize = 22f
        e.setText(km?.toString() ?: "")
        box.addView(e)
        val tvN = TextView(this)
        tvN.text = "Aguja del tanque: sin dato (deslizá si querés marcarla)"
        tvN.textSize = 16f
        tvN.setPadding(0, dp(14), 0, 0)
        box.addView(tvN)
        val nivel = intArrayOf(-1)
        val sb = SeekBar(this)
        sb.max = 8
        sb.progress = 4
        sb.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(s: SeekBar?, v: Int, fromUser: Boolean) {
                if (fromUser) { nivel[0] = v; tvN.text = "Aguja del tanque: " + v + "/8" }
            }
            override fun onStartTrackingTouch(s: SeekBar?) {}
            override fun onStopTrackingTouch(s: SeekBar?) {}
        })
        box.addView(sb)
        AlertDialog.Builder(this)
            .setTitle(if (fin) "Tablero al terminar" else "Tablero al empezar")
            .setView(box)
            .setPositiveButton("Guardar") { _, _ ->
                Store.setTablero(this, Store.today(), if (fin) "fin" else "ini", e.text.toString().trim().toLongOrNull(), if (nivel[0] >= 0) nivel[0] else null)
                refresh()
                toast("Tablero guardado.")
            }
            .setNegativeButton("Cancelar", null)
            .show()
    }

    // ---------- historial ----------
    private fun leerCapturas(uris: List<Uri>) {
        toast("Leyendo " + uris.size + " capturas…")
        val total = intArrayOf(0)
        fun next(i: Int) {
            if (i >= uris.size) {
                toast("Listo: sumé " + total[0] + " paradas nuevas a tus zonas.")
                refresh()
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
        val txt = "Apps que vi:\n" + (if (pk.isEmpty()) "(ninguna todavía)" else pk) +
            "\n\nÚltimo texto leído de DiDi:\n" + (if (ll.isEmpty()) "(nada todavía)" else ll.joinToString("\n")) +
            "\n\nÚltimas pantallas de DiDi con minutos:\n" + Store.snapsTexto(this)
        val t = TextView(this)
        t.text = txt
        t.setTextIsSelectable(true)
        t.setPadding(dp(22), dp(10), dp(22), dp(10))
        val sv = ScrollView(this)
        sv.addView(t)
        AlertDialog.Builder(this).setTitle("Lo que leo").setView(sv)
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
    val destAddr: String?
)

data class Eval(
    val perKm: Double,
    val perHour: Double,
    val score: Double,
    val color: Int,
    val textColor: Int,
    val label: String,
    val zona: String,
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
}

internal class Seg(val min: Int, val km: Double, val idx: Int)

object Parser {
    private val segRx = Regex("(\\d+)\\s*min\\.?\\s*\\(?\\s*([\\d.,]+)\\s*(km|m)\\b\\s*\\)?", RegexOption.IGNORE_CASE)
    private val priceLine = Regex("^\\$\\s*([\\d.]+(?:,\\d{1,2})?)$")
    private val priceAny = Regex("\\$\\s*([\\d.]+(?:,\\d{1,2})?)")
    private val multRx = Regex("(\\d+[.,]\\d+)\\s*x\\b")
    private val decDot = Regex("\\.\\d{1,2}$")
    val minRx = Regex("\\d+\\s*min", RegexOption.IGNORE_CASE)

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

    fun isAddress(l: String): Boolean {
        if (barrioOf(l) == null) return false
        val u = l.uppercase()
        return l.contains(",") || u.contains("CABA") || u.contains("BUENOS AIRES")
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

        var price: Double? = null
        for (l in lines) {
            val m = priceLine.find(l) ?: continue
            price = money(m.groupValues[1])
            if (price != null) break
        }
        if (price == null) {
            val area = if (firstSeg > 0) joined.substring(0, firstSeg) else joined
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

        val p = segs[0]
        val t = segs[1]
        val addrs = lines.filter { isAddress(it) }
        val oA = addrs.getOrNull(0)
        val dA = addrs.getOrNull(1)
        return Pedido(pr, mult, p.min, p.km, t.min, t.km, oA?.let { barrioOf(it) }, dA?.let { barrioOf(it) }, oA, dA)
    }
}

object Evaluator {
    val VERDE: Int = Color.rgb(0x1F, 0x9D, 0x55)
    val AMARILLO: Int = Color.rgb(0xF2, 0xC2, 0x00)
    val ROJO: Int = Color.rgb(0xE0, 0x39, 0x2B)

    fun eval(c: Context, p: Pedido): Eval {
        val km = (p.pKm + p.tKm).coerceAtLeast(0.1)
        val min = (p.pMin + p.tMin).coerceAtLeast(1)
        val perKm = p.price / km
        val perHour = p.price / (min / 60.0)
        val oKm = Store.getD(c, "obj_km", 1000.0)
        val oH = Store.getD(c, "obj_h", 15000.0)
        val rs = ArrayList<Double>()
        if (oKm > 0) rs.add(perKm / oKm)
        if (oH > 0) rs.add(perHour / oH)
        var score = if (rs.isEmpty()) 1.0 else rs.average()

        val peso = Store.getD(c, "zona_peso", 15.0) / 100.0
        val fam = Store.familiarity(c, p.dest)
        val zona: String
        if (fam == null) {
            zona = if (p.dest != null) "Destino: " + p.dest else ""
        } else {
            score *= (1 + peso * (2 * fam - 1))
            val tipo = when {
                fam >= 0.6 -> "zona tuya"
                fam >= 0.3 -> "zona conocida"
                fam > 0 -> "zona poco común"
                else -> "zona nueva para vos"
            }
            zona = "Destino: " + p.dest + " · " + tipo
        }
        val am = Store.getD(c, "amarillo", 85.0) / 100.0
        val color: Int
        val textColor: Int
        val label: String
        if (score >= 1.0) { color = VERDE; textColor = Color.WHITE; label = "Conviene" }
        else if (score >= am) { color = AMARILLO; textColor = Color.BLACK; label = "Justo" }
        else { color = ROJO; textColor = Color.WHITE; label = "No conviene" }
        val ck = Store.costoKm(c)
        return Eval(perKm, perHour, score, color, textColor, label, zona, if (ck != null) ck * km else null)
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
import java.util.Date
import java.util.Locale

class Consumo(val kml: Double?, val precio: Double?, val real: Boolean, val km: Long, val litros: Double)

internal class Punto(val ts: Long, val km: Long, val nivel: Int?)

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

    fun today(): String = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
    private fun hm(ts: Long): String = SimpleDateFormat("HH:mm", Locale.US).format(Date(ts))
    fun key(s: String): String = Normalizer.normalize(s.trim().lowercase(Locale.ROOT), Normalizer.Form.NFD)
        .replace(Regex("\\p{Mn}+"), "").replace(Regex("\\s+"), " ")

    // ---------- combustible ----------
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

    // ---------- tablero ----------
    @Synchronized fun setTablero(c: Context, date: String, which: String, km: Long?, nivel: Int?) {
        val o = obj(c, "tablero.json")
        val d = o.optJSONObject(date) ?: JSONObject()
        val r = JSONObject().put("ts", System.currentTimeMillis())
        if (km != null) r.put("km", km)
        if (nivel != null) r.put("nivel", nivel)
        d.put(which, r)
        o.put(date, d)
        save(c, "tablero.json", o.toString())
    }

    private fun puntos(c: Context): List<Punto> {
        val t = obj(c, "tablero.json")
        val pts = ArrayList<Punto>()
        for (k in t.keys()) {
            val d = t.optJSONObject(k) ?: continue
            for (w in listOf("ini", "fin")) {
                val r = d.optJSONObject(w) ?: continue
                if (r.has("km")) pts.add(Punto(r.getLong("ts"), r.getLong("km"), if (r.has("nivel")) r.getInt("nivel") else null))
            }
        }
        pts.sortBy { it.ts }
        return pts
    }

    fun lastOdo(c: Context): Long? = puntos(c).lastOrNull()?.km

    fun tableroResumen(c: Context): String {
        val d = obj(c, "tablero.json").optJSONObject(today())
        fun part(w: String, n: String): String {
            val r = d?.optJSONObject(w) ?: return n + ": falta la foto"
            var s = n + ": " + (if (r.has("km")) Fmt.int(r.getLong("km")) + " km" else "sin km")
            if (r.has("nivel")) s += " · tanque " + r.getInt("nivel") + "/8"
            return s + " (" + hm(r.getLong("ts")) + ")"
        }
        var s = "Hoy\n" + part("ini", "Al empezar") + "\n" + part("fin", "Al terminar")
        val ini = d?.optJSONObject("ini")
        val fin = d?.optJSONObject("fin")
        if (ini != null && fin != null && ini.has("km") && fin.has("km")) {
            s += "\nHiciste " + Fmt.int(fin.getLong("km") - ini.getLong("km")) + " km"
        }
        return s
    }

    fun consumo(c: Context): Consumo {
        val pts = puntos(c)
        val cargas = arr(c, "cargas.json")
        val precio: Double? = if (cargas.length() > 0) cargas.getJSONObject(cargas.length() - 1).getDouble("pre") else null
        var kml: Double? = null
        var real = false
        var km = 0L
        var lit = 0.0
        if (pts.size >= 2) {
            val a = pts.first()
            val b = pts.last()
            km = b.km - a.km
            for (i in 0 until cargas.length()) {
                val o = cargas.getJSONObject(i)
                val ts = o.getLong("ts")
                if (ts > a.ts && ts <= b.ts) lit += o.getDouble("lit")
            }
            val cap = getD(c, "tanque", 0.0)
            val na = a.nivel
            val nb = b.nivel
            if (cap > 0 && na != null && nb != null) lit += cap * (na - nb) / 8.0
            if (km >= 100 && lit >= 5) { kml = km / lit; real = true }
        }
        if (kml == null) {
            val m = getD(c, "kml_manual", 0.0)
            if (m > 0) kml = m
        }
        return Consumo(kml, precio, real, km, lit)
    }

    fun costoKm(c: Context): Double? {
        val k = consumo(c)
        val kml = k.kml ?: return null
        val pre = k.precio ?: return null
        return if (kml > 0) pre / kml else null
    }

    fun consumoResumen(c: Context): String {
        val k = consumo(c)
        val sb = StringBuilder()
        val kml = k.kml
        if (kml != null) {
            sb.append("Consumo ").append(if (k.real) "real" else "cargado a mano").append(": ")
                .append(Fmt.num(kml, 1)).append(" km por litro")
            if (k.real) sb.append(" (").append(Fmt.int(k.km)).append(" km con ").append(Fmt.num(k.litros, 1)).append(" litros)")
        } else {
            sb.append("Consumo: faltan datos. Necesito al menos 100 km entre dos fotos del tablero y una carga en el medio.")
        }
        val ck = costoKm(c)
        if (ck != null) sb.append("\nCada km te cuesta ").append(Fmt.money(ck)).append(" de combustible.")
        else if (k.precio == null) sb.append("\nCargá combustible una vez para saber el precio del litro.")
        return sb.toString()
    }

    // ---------- zonas ----------
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
            val barrio = Parser.barrioOf(l) ?: continue
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

    @Synchronized fun addTrip(c: Context, p: Pedido) {
        val z = obj(c, "zonas.json")
        val b = z.optJSONObject("b") ?: JSONObject()
        p.origin?.let { bump(b, it) }
        p.dest?.let { bump(b, it) }
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
        val sb = StringBuilder("Aprendí " + total + " paradas en " + l.size + " barrios. Los más tuyos:")
        for (x in l.take(15)) {
            val bars = "█".repeat(maxOf(1, (8.0 * x.second / max).toInt()))
            sb.append("\n").append(bars).append(" ").append(x.first).append(" (").append(x.second).append(")")
        }
        if (total < 10) sb.append("\nCon menos de 10 paradas todavía no las uso en el semáforo.")
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

    @Synchronized fun logPedido(c: Context, p: Pedido, e: Eval) {
        val a = arr(c, "pedidos.json")
        a.put(
            JSONObject().put("ts", System.currentTimeMillis()).put("price", p.price)
                .put("km", fin(p.pKm + p.tKm)).put("min", p.pMin + p.tMin)
                .put("o", p.origin ?: "").put("d", p.dest ?: "").put("v", e.label)
                .put("pkm", fin(e.perKm)).put("ph", fin(e.perHour)).put("acc", false)
        )
        val out = JSONArray()
        for (i in maxOf(0, a.length() - 300) until a.length()) out.put(a.get(i))
        save(c, "pedidos.json", out.toString())
    }

    @Synchronized fun markLastAccepted(c: Context) {
        val a = arr(c, "pedidos.json")
        if (a.length() == 0) return
        a.getJSONObject(a.length() - 1).put("acc", true)
        save(c, "pedidos.json", a.toString())
    }

    fun pedidosResumen(c: Context): String {
        val a = arr(c, "pedidos.json")
        if (a.length() == 0) return "Todavía no leí pedidos."
        val sb = StringBuilder()
        for (i in a.length() - 1 downTo maxOf(0, a.length() - 10)) {
            val o = a.getJSONObject(i)
            sb.append(hm(o.getLong("ts"))).append(" · ").append(o.getString("v")).append(" · ")
                .append(Fmt.money(o.getDouble("price"))).append(" · ")
                .append(Fmt.money(o.getDouble("pkm"))).append(" por km · ")
                .append(Fmt.money(o.getDouble("ph"))).append(" por hora")
            val d = o.optString("d")
            if (d.isNotEmpty()) sb.append(" · a ").append(d)
            if (o.optBoolean("acc")) sb.append(" · tomado")
            sb.append("\n")
        }
        return sb.toString().trim()
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
    android:notificationTimeout="250"
    android:description="@string/a11y_desc" />
EOF_ALVOLANTE
echo "Proyecto generado"
