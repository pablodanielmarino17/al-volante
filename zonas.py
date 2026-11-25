import json, io, zipfile, urllib.request, urllib.parse, os, sys

LOG = []
def log(*a):
    s = " ".join(str(x) for x in a)
    LOG.append(s)
    print("[zonas]", s)

def get(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 al-volante-build"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()

def ckan_resources(base, ids, query):
    res = []
    for pid in ids:
        try:
            d = json.loads(get(base + "/api/3/action/package_show?id=" + pid))
            if d.get("success"):
                res += d["result"].get("resources", [])
                log("paquete", base, pid, len(d["result"].get("resources", [])), "recursos")
        except Exception as e:
            log("falla package_show", base, pid, repr(e)[:120])
    if not res and query:
        try:
            d = json.loads(get(base + "/api/3/action/package_search?rows=5&q=" + urllib.parse.quote(query)))
            for p in d.get("result", {}).get("results", []):
                log("encontrado por busqueda", base, p.get("name"))
                res += p.get("resources", [])
        except Exception as e:
            log("falla package_search", base, repr(e)[:120])
    return res

def geojson_de(resources):
    cands = []
    for r in resources:
        u = r.get("url") or ""
        f = (r.get("format") or "").lower()
        ul = u.lower()
        if "geojson" in f or ul.endswith(".geojson") or ("json" in f and "geo" in ul):
            cands.insert(0, u)
        elif f == "zip" or ul.endswith(".zip"):
            cands.append(u)
    for u in cands:
        try:
            raw = get(u, 180)
            if raw[:2] == b"PK":
                z = zipfile.ZipFile(io.BytesIO(raw))
                for n in z.namelist():
                    if n.lower().endswith((".geojson", ".json")):
                        g = json.loads(z.read(n).decode("utf-8", "replace"))
                        if "features" in g:
                            log("geojson en zip", u, n)
                            return g
                continue
            g = json.loads(raw.decode("utf-8", "replace"))
            if "features" in g:
                log("geojson", u, len(g["features"]), "features")
                return g
        except Exception as e:
            log("falla descarga", u, repr(e)[:120])
    return None

def nombre(props):
    for k, v in props.items():
        kl = k.lower()
        if ("nombre" in kl or kl in ("barrio", "name")) and isinstance(v, str) and v.strip():
            return v.strip()[:60]
    return "Barrio popular"

def provincia(props):
    for k, v in props.items():
        if "provincia" in k.lower() and isinstance(v, str):
            return v.lower()
    return None

def anillos(geom):
    if not geom:
        return []
    t = geom.get("type")
    c = geom.get("coordinates") or []
    if t == "Polygon":
        return [c[0]] if c else []
    if t == "MultiPolygon":
        return [p[0] for p in c if p]
    if t == "GeometryCollection":
        out = []
        for g in geom.get("geometries", []):
            out += anillos(g)
        return out
    return []

# Provincia de Buenos Aires y CABA (caja aproximada)
BOX = (-63.6, -41.2, -56.6, -33.2)

def procesar(g, filtrar_prov, salida, vistos):
    n = 0
    for f in g.get("features", []):
        props = f.get("properties") or {}
        if filtrar_prov:
            pv = provincia(props)
            if pv is not None and "buenos aires" not in pv:
                continue
        nm = nombre(props)
        for ring in anillos(f.get("geometry")):
            pts = []
            lx = ly = None
            for pt in ring:
                try:
                    x, y = float(pt[0]), float(pt[1])
                except Exception:
                    continue
                if abs(x) > 180 or abs(y) > 90:
                    pts = []
                    break
                x = round(x, 5); y = round(y, 5)
                if lx is not None and abs(x - lx) < 0.00012 and abs(y - ly) < 0.00012:
                    continue
                pts += [x, y]
                lx, ly = x, y
            if len(pts) < 6:
                continue
            xs = pts[0::2]; ys = pts[1::2]
            b = [min(xs), min(ys), max(xs), max(ys)]
            if b[2] < BOX[0] or b[0] > BOX[2] or b[3] < BOX[1] or b[1] > BOX[3]:
                continue
            clave = (round(b[0], 4), round(b[1], 4), round(b[2], 4), round(b[3], 4))
            if clave in vistos:
                continue
            vistos.add(clave)
            salida.append({"n": nm, "b": b, "p": pts})
            n += 1
    return n

salida = []
vistos = set()
try:
    g = geojson_de(ckan_resources("https://data.buenosaires.gob.ar", ["barrios-populares"], "barrios populares"))
    if g:
        log("Ciudad:", procesar(g, False, salida, vistos), "poligonos")
    else:
        log("Ciudad: no se pudo bajar")
except Exception as e:
    log("Ciudad error", repr(e)[:160])
try:
    res = ckan_resources("https://datos.gob.ar", ["habitat-registro-nacional-barrios-populares"], "registro nacional barrios populares")
    g = geojson_de(res)
    if not g:
        res = ckan_resources("https://datosabiertos.desarrollosocial.gob.ar", ["registro-nacional-de-barrios-populares"], "barrios populares")
        g = geojson_de(res)
    if g:
        log("Provincia (RENABAP):", procesar(g, True, salida, vistos), "poligonos")
    else:
        log("RENABAP: no se pudo bajar")
except Exception as e:
    log("RENABAP error", repr(e)[:160])

log("Total:", len(salida), "poligonos")
if salida:
    os.makedirs("proj/app/src/main/assets", exist_ok=True)
    with open("proj/app/src/main/assets/zonas.json", "w") as fh:
        json.dump(salida, fh, separators=(",", ":"), ensure_ascii=False)
    log("Tamano:", os.path.getsize("proj/app/src/main/assets/zonas.json"), "bytes")
os.makedirs("dist", exist_ok=True)
with open("dist/ZONAS_LOG.txt", "w") as fh:
    fh.write("\n".join(LOG) + "\n")
