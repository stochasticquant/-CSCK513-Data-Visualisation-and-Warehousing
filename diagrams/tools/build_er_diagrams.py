"""build_er_diagrams.py

Draws the two ER diagrams the report needs, straight from the live database definitions:
  diagrams/er_staging.svg / .png   - gravity_staging (stg schema, no keys by design)
  diagrams/er_warehouse.svg / .png - gravity_dw star schema (+ etl/dq control tables)

Columns, types, primary keys, unique keys and foreign keys are read from SQL Server's
catalog views with sqlcmd, so the diagrams always match what is actually built.
PNGs are rendered with Microsoft Edge in headless mode.

Usage:  python build_er_diagrams.py
"""
import html
import os
import subprocess
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent          # the diagrams folder
SERVER = "localhost"
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"

META_SQL = """
SET NOCOUNT ON;
SELECT s.name, t.name, c.name,
       ty.name + CASE WHEN ty.name IN ('varchar','char','nvarchar','nchar')
                        THEN '(' + CAST(CASE WHEN ty.name LIKE 'n%' THEN c.max_length/2 ELSE c.max_length END AS VARCHAR) + ')'
                      WHEN ty.name = 'decimal' THEN '(' + CAST(c.precision AS VARCHAR) + ',' + CAST(c.scale AS VARCHAR) + ')'
                      ELSE '' END,
       CAST(c.is_nullable AS INT), CAST(c.is_identity AS INT),
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                         WHERE i.object_id = t.object_id AND i.is_primary_key = 1 AND ic.column_id = c.column_id) THEN 1 ELSE 0 END,
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                         WHERE i.object_id = t.object_id AND i.is_unique_constraint = 1 AND ic.column_id = c.column_id) THEN 1 ELSE 0 END,
       COALESCE((SELECT TOP 1 OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.' + OBJECT_NAME(fk.referenced_object_id)
                 FROM sys.foreign_key_columns fk WHERE fk.parent_object_id = t.object_id AND fk.parent_column_id = c.column_id), ''),
       c.column_id
FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.columns c ON c.object_id = t.object_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
ORDER BY s.name, t.name, c.column_id;
"""


def read_tables(db):
    out = subprocess.run(["sqlcmd", "-S", SERVER, "-E", "-C", "-d", db, "-W", "-h", "-1", "-s", "|", "-Q", META_SQL],
                         capture_output=True, text=True, check=True).stdout
    tables = {}
    for line in out.splitlines():
        p = line.split("|")
        if len(p) < 10:
            continue
        key = f"{p[0]}.{p[1]}"
        tables.setdefault(key, []).append(dict(name=p[2], type=p[3], null=p[4] == "1", ident=p[5] == "1",
                                               pk=p[6] == "1", uq=p[7] == "1", fk=p[8]))
    return tables


# ---------------------------------------------------------------- drawing
FONT = "Segoe UI, Arial, sans-serif"
ROW, HEAD, PAD = 22, 34, 8


class Box:
    def __init__(self, name, cols, x, y, w, colour, label=None):
        self.name, self.cols, self.x, self.y, self.w, self.colour = name, cols, x, y, w, colour
        self.label = label or name
        self.h = HEAD + len(cols) * ROW + PAD

    def row_y(self, col_name):
        for i, c in enumerate(self.cols):
            if c["name"] == col_name:
                return self.y + HEAD + i * ROW + ROW / 2 + 2
        return self.y + HEAD / 2

    def svg(self):
        s = [f'<g><rect x="{self.x}" y="{self.y}" width="{self.w}" height="{self.h}" rx="6" fill="#ffffff" stroke="{self.colour}" stroke-width="1.5"/>',
             f'<path d="M{self.x},{self.y + 6} a6,6 0 0 1 6,-6 h{self.w - 12} a6,6 0 0 1 6,6 v{HEAD - 6} h-{self.w} z" fill="{self.colour}"/>',
             f'<text x="{self.x + 10}" y="{self.y + 22}" font-family="{FONT}" font-size="14" font-weight="600" fill="#ffffff">{html.escape(self.label)}</text>']
        for i, c in enumerate(self.cols):
            ry = self.y + HEAD + i * ROW
            if i % 2:
                s.append(f'<rect x="{self.x + 1}" y="{ry}" width="{self.w - 2}" height="{ROW}" fill="#f4f6f9"/>')
            badge = "PK" if c["pk"] else ("FK" if c["fk"] else ("UQ" if c["uq"] else ""))
            bcol = {"PK": "#b7791f", "FK": "#2b6cb0", "UQ": "#6b7280"}.get(badge, "")
            if badge:
                s.append(f'<rect x="{self.x + 8}" y="{ry + 4}" width="24" height="14" rx="3" fill="{bcol}"/>'
                         f'<text x="{self.x + 20}" y="{ry + 15}" text-anchor="middle" font-family="{FONT}" font-size="9" font-weight="700" fill="#fff">{badge}</text>')
            weight = "600" if (c["pk"] or c["fk"]) else "400"
            name = html.escape(c["name"]) + (" ◆" if c.get("ident") else "")
            s.append(f'<text x="{self.x + 40}" y="{ry + 15}" font-family="{FONT}" font-size="12" font-weight="{weight}" fill="#1f2937">{name}</text>')
            typ = html.escape(c["type"]) + ("" if c["null"] else " NN")
            s.append(f'<text x="{self.x + self.w - 10}" y="{ry + 15}" text-anchor="end" font-family="{FONT}" font-size="11" fill="#6b7280">{typ}</text>')
        s.append("</g>")
        return "\n".join(s)


def relationship(one, many, one_col, many_col):
    """Line from the dimension's key (one) to the fact's foreign key (many), crow's foot at the many end."""
    oy, my = one.row_y(one_col), many.row_y(many_col)
    if one.x + one.w < many.x:            # dimension on the left
        x1, x2, d = one.x + one.w, many.x, 1
    elif many.x + many.w < one.x:         # dimension on the right
        x1, x2, d = one.x, many.x + many.w, -1
    else:                                 # dimension above / below: route via the fact's side
        x1, x2, d = one.x + one.w / 2, many.x, 1
    midx = (x1 + x2) / 2
    path = f'M{x1},{oy} H{midx} V{my} H{x2}' if abs(x2 - x1) > 40 else f'M{x1},{oy} L{x2},{my}'
    s = [f'<path d="{path}" fill="none" stroke="#4b5563" stroke-width="1.6"/>']
    # "one and only one" bars at the dimension end
    for off in (10, 16):
        bx = x1 + d * off
        s.append(f'<line x1="{bx}" y1="{oy - 7}" x2="{bx}" y2="{oy + 7}" stroke="#4b5563" stroke-width="1.6"/>')
    # crow's foot ("many") at the fact end
    fx = x2 - d * 14
    for dy in (-8, 0, 8):
        s.append(f'<line x1="{fx}" y1="{my}" x2="{x2}" y2="{my + dy}" stroke="#4b5563" stroke-width="1.6"/>')
    s.append(f'<line x1="{x2 - d * 18}" y1="{my - 7}" x2="{x2 - d * 18}" y2="{my + 7}" stroke="#4b5563" stroke-width="1.6"/>')
    return "\n".join(s)


def frame(x, y, w, h, title, colour):
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{colour}" fill-opacity="0.06" stroke="{colour}" stroke-dasharray="6 4"/>'
            f'<text x="{x + 14}" y="{y + 24}" font-family="{FONT}" font-size="15" font-weight="600" fill="{colour}">{html.escape(title)}</text>')


def text_block(x, y, lines, size=12, colour="#374151"):
    return "\n".join(f'<text x="{x}" y="{y + i * (size + 6)}" font-family="{FONT}" font-size="{size}" fill="{colour}" xml:space="preserve">{html.escape(t)}</text>'
                     for i, t in enumerate(lines))


def write(name, width, height, title, subtitle, body):
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">'
           f'<rect width="100%" height="100%" fill="#ffffff"/>'
           f'<text x="30" y="42" font-family="{FONT}" font-size="24" font-weight="700" fill="#111827">{html.escape(title)}</text>'
           f'<text x="30" y="68" font-family="{FONT}" font-size="13" fill="#4b5563">{html.escape(subtitle)}</text>'
           f'{body}</svg>')
    svg_path = OUT / f"{name}.svg"
    svg_path.write_text(svg, encoding="utf-8")
    html_path = OUT / "tools" / f"_{name}.html"
    html_path.write_text(f'<html><body style="margin:0">{svg}</body></html>', encoding="utf-8")
    png_path = OUT / f"{name}.png"
    subprocess.run([EDGE, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=2",
                    f"--window-size={width},{height}", f"--screenshot={png_path}", html_path.as_uri()],
                   check=True, capture_output=True)
    html_path.unlink()
    print("wrote", svg_path.name, png_path.name)


# ---------------------------------------------------------------- staging
def staging():
    t = read_tables("gravity_staging")
    oltp = ["book", "book_language", "publisher", "customer", "address", "country",
            "cust_order", "order_line", "order_history", "order_status", "shipping_method"]
    files = ["survey", "country_region"]
    W, GAP = 250, 24
    body, boxes = [], []
    # OLTP copies: 4 columns
    fx, fy = 30, 100
    cols_x = [fx + 20 + i * (W + GAP) for i in range(4)]
    col_y = [fy + 44] * 4
    for name in oltp:
        i = col_y.index(min(col_y))                                 # shortest column first
        b = Box(f"stg.{name}", t[f"stg.{name}"], cols_x[i], col_y[i], W, "#2b6cb0")
        boxes.append(b); col_y[i] += b.h + GAP
    oltp_w, oltp_h = 4 * (W + GAP) + 16, max(col_y) - fy + 4
    body.append(frame(fx, fy, oltp_w, oltp_h, "Copied 1:1 from gravity_books (OLTP), 11 tables", "#2b6cb0"))
    # CSV files
    cx = fx + oltp_w + 30
    y = fy + 44
    fw = 290
    for name in files:
        b = Box(f"stg.{name}", t[f"stg.{name}"], cx + 20, y, fw - 40, "#c05621")
        boxes.append(b); y += b.h + GAP
    body.append(frame(cx, fy, fw, y - fy + 4, "Loaded from CSV files", "#c05621"))
    notes_y = y + 40
    body.append(text_block(cx, notes_y, [
        "Design notes",
        "• No primary or foreign keys: a dirty row",
        "  can never make the extract fail.",
        "• Columns mirror the source; CSV columns",
        "  stay as text, converted in the transform.",
        "• load_datetime (NN, DEFAULT SYSDATETIME())",
        "  records when each row was loaded.",
        "• Tables are truncated and reloaded on",
        "  every run (re-runnable).",
        "",
        "Logical links used by the transform",
        "(not enforced in staging):",
        "  book → book_language, publisher",
        "  address → country → country_region",
        "  cust_order → customer, address,",
        "               shipping_method",
        "  order_line → cust_order, book",
        "  order_history → cust_order, order_status",
        "  survey.customer_id → customer",
        "",
        "NN = NOT NULL",
    ], 12))
    body.extend(b.svg() for b in boxes)
    width = cx + fw + 30
    height = max(fy + oltp_h, notes_y + 21 * 18) + 30
    write("er_staging", int(width), int(height), "Staging database: gravity_staging (schema stg)",
          "Transient landing area between the operational database and the warehouse. 13 tables, deliberately without keys or constraints.",
          "\n".join(body))


# ---------------------------------------------------------------- warehouse
def warehouse():
    t = read_tables("gravity_dw")
    star = {"fact": "#1e3a8a", "dim": "#0f766e", "ctl": "#6b7280"}
    fact = Box("dbo.fact_sales", t["dbo.fact_sales"], 700, 330, 330, star["fact"], "fact_sales  (grain: one order line)")
    d_date = Box("dbo.dim_date", t["dbo.dim_date"], 60, 100, 300, star["dim"], "dim_date")
    d_cust = Box("dbo.dim_customer", t["dbo.dim_customer"], 60, 470, 300, star["dim"], "dim_customer")
    d_ship = Box("dbo.dim_shipping_method", t["dbo.dim_shipping_method"], 700, 760, 330, star["dim"], "dim_shipping_method")
    d_book = Box("dbo.dim_book", t["dbo.dim_book"], 1370, 100, 310, star["dim"], "dim_book")
    d_loc = Box("dbo.dim_location", t["dbo.dim_location"], 1370, 470, 310, star["dim"], "dim_location")
    body = [relationship(d_date, fact, "date_key", "order_date_key"),
            relationship(d_cust, fact, "customer_key", "customer_key"),
            relationship(d_book, fact, "book_key", "book_key"),
            relationship(d_loc, fact, "location_key", "location_key")]
    # shipping sits below the fact: vertical link
    sx = d_ship.x + d_ship.w / 2
    fy = fact.y + fact.h
    body.append(f'<path d="M{sx},{d_ship.y} V{fy}" stroke="#4b5563" stroke-width="1.6" fill="none"/>')
    for off in (10, 16):
        body.append(f'<line x1="{sx - 7}" y1="{d_ship.y - off}" x2="{sx + 7}" y2="{d_ship.y - off}" stroke="#4b5563" stroke-width="1.6"/>')
    for dx in (-8, 0, 8):
        body.append(f'<line x1="{sx}" y1="{fy + 14}" x2="{sx + dx}" y2="{fy}" stroke="#4b5563" stroke-width="1.6"/>')
    body.append(f'<line x1="{sx - 7}" y1="{fy + 18}" x2="{sx + 7}" y2="{fy + 18}" stroke="#4b5563" stroke-width="1.6"/>')
    body.append(f'<text x="{sx + 10}" y="{fy + 50}" font-family="{FONT}" font-size="11" fill="#6b7280">shipping_key</text>')

    # control tables (not part of the star)
    cy0 = d_ship.y + d_ship.h + 50
    ctl = []
    x = 60
    for name, w in (("etl.config", 330), ("etl.audit", 300), ("dq.check_log", 300), ("dq.fact_rejects", 300)):
        b = Box(name, t[name], x + 20, cy0 + 44, w, star["ctl"]); ctl.append(b); x += w + 40
    ch = max(b.h for b in ctl) + 64
    body.append(frame(60, cy0, x - 60 + 0, ch, "Control tables (schemas etl and dq): ETL configuration, audit log and data-quality results, outside the star", "#6b7280"))
    for b in (fact, d_date, d_cust, d_ship, d_book, d_loc, *ctl):
        body.append(b.svg())
    # legend
    lx, ly = 60, cy0 + ch + 34
    body.append(text_block(lx, ly, [
        "Legend:  PK primary key (surrogate, INT IDENTITY ◆)  ·  FK foreign key  ·  UQ unique business key from the source  ·  NN NOT NULL"
        "  ·  ─|| one   ─< many",
        "Every dimension holds an 'Unknown' member with key -1, so fact rows whose lookups fail still load and can be counted.",
        "order_id and line_id in fact_sales are degenerate dimensions (kept for counting orders and tracing lines to the source).",
    ], 12))
    width = max(x + 40, d_book.x + d_book.w + 60, d_loc.x + d_loc.w + 60)
    write("er_warehouse", int(width), int(ly + 3 * 18 + 20), "Data warehouse: gravity_dw (star schema)",
          "One fact table at order-line grain, surrounded by five conformed dimensions. Power BI reads only these tables.",
          "\n".join(body))


if __name__ == "__main__":
    staging()
    warehouse()
