/**
 * Minimal XLSX (OOXML) → CSV for BBVA Movimientos sheets.
 * Uses DecompressionStream(deflate-raw). No external deps.
 * Exposes: window.strmXlsxToCsv(arrayBuffer) -> Promise<string>
 *          window.strmXlsxToRows(arrayBuffer, {sheet}) -> Promise<{sheets, sheet, rows, csv}>
 *          (sql/017: any sheet, every row, dates as YYYY-MM-DD)
 */
(function (global) {
  "use strict";

  function decodeUtf8(bytes) {
    return new TextDecoder("utf-8").decode(bytes);
  }

  async function inflateRaw(bytes) {
    if (typeof DecompressionStream === "undefined") {
      throw new Error("This browser cannot unpack XLSX (missing DecompressionStream).");
    }
    const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
    const ab = await new Response(stream).arrayBuffer();
    return new Uint8Array(ab);
  }

  async function unzip(arrayBuffer) {
    const view = new DataView(arrayBuffer);
    const bytes = new Uint8Array(arrayBuffer);
    // Find End of Central Directory
    let eocd = -1;
    for (let i = bytes.length - 22; i >= 0; i -= 1) {
      if (view.getUint32(i, true) === 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) {
      throw new Error("XLSX is not a valid ZIP (missing EOCD)");
    }
    const entryCount = view.getUint16(eocd + 10, true);
    let cdOffset = view.getUint32(eocd + 16, true);
    const files = {};
    for (let n = 0; n < entryCount; n += 1) {
      if (view.getUint32(cdOffset, true) !== 0x02014b50) {
        throw new Error("XLSX ZIP central directory is corrupt");
      }
      const compression = view.getUint16(cdOffset + 10, true);
      const compSize = view.getUint32(cdOffset + 20, true);
      const nameLen = view.getUint16(cdOffset + 28, true);
      const extraLen = view.getUint16(cdOffset + 30, true);
      const commentLen = view.getUint16(cdOffset + 32, true);
      const localOffset = view.getUint32(cdOffset + 42, true);
      const name = decodeUtf8(bytes.subarray(cdOffset + 46, cdOffset + 46 + nameLen));
      if (view.getUint32(localOffset, true) !== 0x04034b50) {
        throw new Error(`XLSX local header missing for ${name}`);
      }
      const localNameLen = view.getUint16(localOffset + 26, true);
      const localExtraLen = view.getUint16(localOffset + 28, true);
      const dataStart = localOffset + 30 + localNameLen + localExtraLen;
      // Prefer sizes from central directory (local may be zero when bit 3 is set).
      let size = compSize;
      if (size === 0) {
        size = view.getUint32(localOffset + 18, true);
      }
      const data = bytes.subarray(dataStart, dataStart + size);
      let content;
      if (compression === 0) {
        content = data;
      } else if (compression === 8) {
        content = await inflateRaw(data);
      } else {
        throw new Error(`Unsupported XLSX compression ${compression} for ${name}`);
      }
      files[name] = content;
      cdOffset += 46 + nameLen + extraLen + commentLen;
    }
    return files;
  }

  function parseSharedStrings(xml) {
    const strings = [];
    const siRe = /<si\b[^>]*>([\s\S]*?)<\/si>/g;
    let match;
    while ((match = siRe.exec(xml))) {
      const body = match[1];
      const parts = [];
      const tRe = /<t([^>]*)>([\s\S]*?)<\/t>/g;
      let tMatch;
      while ((tMatch = tRe.exec(body))) {
        parts.push(decodeXml(tMatch[2]));
      }
      strings.push(parts.join(""));
    }
    return strings;
  }

  function decodeXml(text) {
    return text
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'")
      .replace(/&amp;/g, "&");
  }

  function colLettersToIndex(letters) {
    let n = 0;
    for (let i = 0; i < letters.length; i += 1) {
      n = n * 26 + (letters.charCodeAt(i) - 64);
    }
    return n - 1;
  }

  function cellValue(attrs, body, shared) {
    const type = /\bt="([^"]+)"/.exec(attrs);
    const t = type ? type[1] : "";
    const vMatch = /<v([^>]*)>([\s\S]*?)<\/v>/.exec(body);
    const isMatch = /<is>([\s\S]*?)<\/is>/.exec(body);
    if (t === "s" && vMatch) {
      return shared[Number(vMatch[2])] ?? "";
    }
    if ((t === "inlineStr" || t === "str") && isMatch) {
      const tInline = /<t([^>]*)>([\s\S]*?)<\/t>/.exec(isMatch[1]);
      return tInline ? decodeXml(tInline[2]) : "";
    }
    if (t === "str" && vMatch) {
      return decodeXml(vMatch[2]);
    }
    if (vMatch) {
      return decodeXml(vMatch[2]);
    }
    if (isMatch) {
      const tInline = /<t([^>]*)>([\s\S]*?)<\/t>/.exec(isMatch[1]);
      return tInline ? decodeXml(tInline[2]) : "";
    }
    return "";
  }

  function parseSheet(xml, shared) {
    const rows = new Map();
    const rowRe = /<row\b[^>]*>([\s\S]*?)<\/row>/g;
    let rowMatch;
    while ((rowMatch = rowRe.exec(xml))) {
      const rowXml = rowMatch[0];
      const rAttr = /\br="(\d+)"/.exec(rowXml);
      if (!rAttr) continue;
      const rowNum = Number(rAttr[1]);
      const cells = [];
      const cellRe = /<c\b([^>]*)>([\s\S]*?)<\/c>|<c\b([^>]*)\/>/g;
      let cellMatch;
      while ((cellMatch = cellRe.exec(rowXml))) {
        const attrs = cellMatch[1] || cellMatch[3] || "";
        const body = cellMatch[2] || "";
        const ref = /\br="([A-Z]+)(\d+)"/.exec(attrs);
        if (!ref) continue;
        const col = colLettersToIndex(ref[1]);
        cells[col] = cellValue(attrs, body, shared);
      }
      let last = cells.length - 1;
      while (last >= 0 && (cells[last] == null || cells[last] === "")) last -= 1;
      if (last >= 0) {
        const row = [];
        for (let i = 0; i <= last; i += 1) row.push(cells[i] == null ? "" : String(cells[i]));
        rows.set(rowNum, row);
      }
    }
    return [...rows.entries()].sort((a, b) => a[0] - b[0]).map(([, row]) => row);
  }

  function csvEscape(value) {
    const text = String(value ?? "").replace(/\r?\n/g, " ").trimEnd();
    if (/[",\r\n]/.test(text)) {
      return `"${text.replaceAll('"', '""')}"`;
    }
    return text;
  }

  function rowsToCsv(rows) {
    return rows.map((row) => row.map(csvEscape).join(",")).join("\n") + (rows.length ? "\n" : "");
  }

  function isSectionRow(row) {
    if (!row || !row.length) return true;
    const first = String(row[0] || "").trim();
    if (!first) return true;
    if (/digital\s*\*/i.test(first) || /titular\s*\*/i.test(first)) return true;
    if (/detalle de movimientos/i.test(first)) return true;
    if (/n[uú]mero de tarjeta/i.test(first)) return true;
    if (/^cuenta:/i.test(first)) return true;
    if (/bbva m[eé]xico/i.test(first)) return true;
    return false;
  }

  function normCell(c) {
    return String(c ?? "")
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "")
      .toLowerCase()
      .replace(/\s+/g, " ")
      .trim();
  }

  // BBVA installments ("Meses sin intereses"): a header with Fecha, Mensualidad and Pagos.
  function looksLikeInstallmentHeader(row) {
    const joined = new Set(row.map(normCell));
    return joined.has("fecha") && joined.has("mensualidad") && joined.has("pagos");
  }

  const ONE_COLUMN_INSTALLMENT_LABELS = ["fecha", "descripcion", "compra", "mensualidad", "pagos", "interes", "saldo actual"];

  // BBVA web list pasted into one column: one value per row, starting with the 7 labels.
  // Sent as one value per line; SQL (sql/011 reshape_one_column_installments) regroups it.
  function isOneColumnInstallments(rows) {
    const values = rows.filter((row) => row.length && String(row[0] ?? "").trim() !== "");
    if (values.length < 8 || values.some((row) => row.slice(1).some((c) => String(c ?? "").trim() !== ""))) {
      return false;
    }
    return ONE_COLUMN_INSTALLMENT_LABELS.every((label, i) => normCell(values[i][0]) === label);
  }

  function looksLikeHeader(row) {
    const norm = row.map(normCell);
    const joined = new Set(norm);
    return joined.has("fecha") && (joined.has("cargo") || joined.has("cargos")) && (joined.has("abono") || joined.has("abonos"));
  }

  function looksLikeDate(text) {
    return /^\d{2}\/\d{2}\/\d{4}$/.test(String(text || "").trim()) || /^\d{4}-\d{2}-\d{2}$/.test(String(text || "").trim());
  }

  async function strmXlsxToCsv(arrayBuffer) {
    const files = await unzip(arrayBuffer);
    const sharedXml = files["xl/sharedStrings.xml"] ? decodeUtf8(files["xl/sharedStrings.xml"]) : "";
    const shared = sharedXml ? parseSharedStrings(sharedXml) : [];
    let sheetPath = "xl/worksheets/sheet1.xml";
    const wb = files["xl/workbook.xml"] ? decodeUtf8(files["xl/workbook.xml"]) : "";
    const rels = files["xl/_rels/workbook.xml.rels"] ? decodeUtf8(files["xl/_rels/workbook.xml.rels"]) : "";
    const sheetNameMatch = /name="Movimientos"[^>]*r:id="([^"]+)"/.exec(wb);
    if (sheetNameMatch) {
      const rid = sheetNameMatch[1];
      const target = new RegExp(`Id="${rid}"[^>]*Target="([^"]+)"`).exec(rels);
      if (target) {
        const t = target[1].replace(/^\//, "");
        sheetPath = t.startsWith("xl/") ? t : `xl/${t}`;
      }
    }
    const sheetBytes = files[sheetPath] || files["xl/worksheets/sheet1.xml"];
    if (!sheetBytes) {
      throw new Error("XLSX has no worksheet");
    }
    const allRows = parseSheet(decodeUtf8(sheetBytes), shared);
    if (isOneColumnInstallments(allRows)) {
      return rowsToCsv(allRows.filter((row) => row.length && String(row[0] ?? "").trim() !== "").map((row) => [row[0]]));
    }
    const headerIdx = allRows.findIndex(looksLikeHeader);
    if (headerIdx < 0) {
      const planIdx = allRows.findIndex(looksLikeInstallmentHeader);
      if (planIdx >= 0) {
        const plan = [allRows[planIdx]];
        for (let i = planIdx + 1; i < allRows.length; i += 1) {
          const row = allRows[i];
          if (isSectionRow(row)) continue;
          if (normCell(row[0]) === "total") break;
          const padded = row.slice();
          while (padded.length < plan[0].length) padded.push("");
          plan.push(padded.slice(0, plan[0].length));
        }
        if (plan.length < 2) {
          throw new Error("XLSX has no installment rows");
        }
        return rowsToCsv(plan);
      }
      throw new Error("XLSX has no FECHA/CARGO/ABONO (or installment) header row");
    }
    const out = [allRows[headerIdx]];
    for (let i = headerIdx + 1; i < allRows.length; i += 1) {
      const row = allRows[i];
      if (isSectionRow(row)) continue;
      if (!looksLikeDate(row[0])) continue;
      const width = out[0].length;
      const padded = row.slice();
      while (padded.length < width) padded.push("");
      out.push(padded.slice(0, width));
    }
    if (out.length < 2) {
      throw new Error("XLSX has no movement rows");
    }
    return rowsToCsv(out);
  }

  /**
   * Working CSV name sent as body.filename (statement_uploads_f.original_filename).
   * The name the user picked is sent untouched as body.chosen_filename (sql/013) and is
   * what the page shows; the vault key is built in SQL (curated_standard_key).
   * Spreadsheet uploads always become bank_account_period.csv.
   * Native CSV keeps its name when it already carries bank or account;
   * otherwise the same canonical form is used. Extension is always .csv.
   */
  function strmStoredUploadFilename(originalName, meta) {
    const bank = String((meta && meta.bank) || "").trim();
    const account = String((meta && meta.accountNumber) || "").trim();
    const period = String((meta && meta.period) || "").trim();
    let name = String(originalName || "statement").trim() || "statement";
    const fromSheet = /\.(xlsx|xlsm|xls)$/i.test(name);
    if (fromSheet) {
      name = name.replace(/\.(xlsx|xlsm|xls)$/i, ".csv");
    } else if (!/\.csv$/i.test(name)) {
      name = name + ".csv";
    }
    const lower = name.toLowerCase();
    const hasBank = bank && lower.indexOf(bank.toLowerCase()) >= 0;
    const hasAccount = account && lower.indexOf(account.toLowerCase()) >= 0;
    if (fromSheet || (!hasBank && !hasAccount)) {
      const parts = [bank, account, period].filter(Boolean);
      name = (parts.length ? parts.join("_") : "statement") + ".csv";
    }
    return name.replace(/[^\w.\-]+/g, "_").replace(/_+/g, "_").replace(/^_|_$/g, "");
  }

  // --- sql/017: any spreadsheet, every row (Investments & Assets column map) -------------
  // Date-formatted cells (built-in formats 14-22, 45-47 or a custom format with d/m/y and
  // no hour-only code) become YYYY-MM-DD; other cells keep the stored value.
  const BUILTIN_DATE_FORMATS = new Set([14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 46, 47]);

  function dateStyleIndexes(stylesXml) {
    const custom = new Map();
    const fmtRe = /<numFmt\b[^>]*numFmtId="(\d+)"[^>]*formatCode="([^"]*)"/g;
    let match;
    while ((match = fmtRe.exec(stylesXml))) {
      const code = decodeXml(match[2]).replace(/\[[^\]]*\]|"[^"]*"|\\./g, "").toLowerCase();
      custom.set(Number(match[1]), /[dy]/.test(code) || /m{3,}/.test(code));
    }
    const dates = new Set();
    const xfs = /<cellXfs\b[^>]*>([\s\S]*?)<\/cellXfs>/.exec(stylesXml);
    if (!xfs) return dates;
    const xfRe = /<xf\b([^>]*?)(?:\/>|>)/g;
    let index = 0;
    while ((match = xfRe.exec(xfs[1]))) {
      const id = Number((/numFmtId="(\d+)"/.exec(match[1]) || [])[1] || 0);
      if (BUILTIN_DATE_FORMATS.has(id) || custom.get(id) === true) dates.add(index);
      index += 1;
    }
    return dates;
  }

  function serialToIso(serial) {
    const days = Math.floor(Number(serial));
    if (!Number.isFinite(days) || days < 1) return String(serial);
    const date = new Date(Date.UTC(1899, 11, 30) + days * 86400000);
    return date.toISOString().slice(0, 10);
  }

  function parseSheetRaw(xml, shared, dateStyles) {
    const rows = [];
    const rowRe = /<row\b[^>]*>([\s\S]*?)<\/row>|<row\b[^>]*\/>/g;
    let rowMatch;
    while ((rowMatch = rowRe.exec(xml))) {
      const rowXml = rowMatch[0];
      const rAttr = /\br="(\d+)"/.exec(rowXml);
      const rowNum = rAttr ? Number(rAttr[1]) : rows.length + 1;
      const cells = [];
      const cellRe = /<c\b([^>]*)>([\s\S]*?)<\/c>|<c\b([^>]*)\/>/g;
      let cellMatch;
      while ((cellMatch = cellRe.exec(rowXml))) {
        const attrs = cellMatch[1] || cellMatch[3] || "";
        const body = cellMatch[2] || "";
        const ref = /\br="([A-Z]+)(\d+)"/.exec(attrs);
        const col = ref ? colLettersToIndex(ref[1]) : cells.length;
        let value = cellValue(attrs, body, shared);
        const style = /\bs="(\d+)"/.exec(attrs);
        const type = (/\bt="([^"]+)"/.exec(attrs) || [])[1] || "n";
        if (style && type === "n" && value !== "" && dateStyles.has(Number(style[1])) && /^\d+(\.\d+)?$/.test(value)) {
          value = serialToIso(value);
        } else if (type === "n" && /^-?\d+\.\d{10,}$/.test(value)) {
          value = String(Number(value)); // 9064.9500000000007 -> 9064.95
        }
        cells[col] = value;
      }
      while (rows.length < rowNum - 1) rows.push([]);
      const row = [];
      for (let i = 0; i < cells.length; i += 1) row.push(cells[i] == null ? "" : String(cells[i]));
      while (row.length && row[row.length - 1] === "") row.pop();
      rows.push(row);
    }
    while (rows.length && rows[rows.length - 1].length === 0) rows.pop();
    return rows;
  }

  function workbookSheets(files) {
    const wb = files["xl/workbook.xml"] ? decodeUtf8(files["xl/workbook.xml"]) : "";
    const rels = files["xl/_rels/workbook.xml.rels"] ? decodeUtf8(files["xl/_rels/workbook.xml.rels"]) : "";
    const sheets = [];
    const sheetRe = /<sheet\b([^>]*)\/?>/g;
    let match;
    while ((match = sheetRe.exec(wb))) {
      const name = decodeXml((/\bname="([^"]*)"/.exec(match[1]) || [])[1] || `Sheet${sheets.length + 1}`);
      const rid = (/\br:id="([^"]+)"/.exec(match[1]) || [])[1];
      const target = rid ? new RegExp(`Id="${rid}"[^>]*Target="([^"]+)"`).exec(rels) : null;
      let path = target ? target[1].replace(/^\//, "") : `worksheets/sheet${sheets.length + 1}.xml`;
      path = path.startsWith("xl/") ? path : `xl/${path}`;
      sheets.push({ name, path });
    }
    if (!sheets.length && files["xl/worksheets/sheet1.xml"]) {
      sheets.push({ name: "Sheet1", path: "xl/worksheets/sheet1.xml" });
    }
    return sheets;
  }

  /**
   * Every row of one sheet (default: the first), dates as YYYY-MM-DD.
   * Returns { sheets: [names], sheet: name, rows: string[][], csv: string }.
   */
  async function strmXlsxToRows(arrayBuffer, options) {
    const files = await unzip(arrayBuffer);
    const sharedXml = files["xl/sharedStrings.xml"] ? decodeUtf8(files["xl/sharedStrings.xml"]) : "";
    const shared = sharedXml ? parseSharedStrings(sharedXml) : [];
    const styles = files["xl/styles.xml"] ? dateStyleIndexes(decodeUtf8(files["xl/styles.xml"])) : new Set();
    const sheets = workbookSheets(files);
    const wanted = options && options.sheet;
    const picked = sheets.find((sheet) => sheet.name === wanted) || sheets[0];
    if (!picked || !files[picked.path]) {
      throw new Error("XLSX has no worksheet");
    }
    const rows = parseSheetRaw(decodeUtf8(files[picked.path]), shared, styles);
    return { sheets: sheets.map((sheet) => sheet.name), sheet: picked.name, rows, csv: rowsToCsv(rows) };
  }

  global.strmXlsxToRows = strmXlsxToRows;
  global.strmXlsxToCsv = strmXlsxToCsv;
  global.strmStoredUploadFilename = strmStoredUploadFilename;
})(typeof window !== "undefined" ? window : globalThis);
