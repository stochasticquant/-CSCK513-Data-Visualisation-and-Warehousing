// BuildTransformPackage.cs
// Generates the SSIS package Transform_Load_DW.dtsx (SQL Server 2025 / SSIS 17).
//
// Control flow
//   SQL Run data-quality checks   (dq.usp_run_checks -> dq.check_log)
//   -> SQL Prepare full load      (etl.usp_prepare_full_load: empty the star schema, keep -1 members)
//   -> SQL Load dim_date          (etl.usp_load_dim_date: calendar + Pre/Post-campaign)
//   -> SEQ Load dimensions        (dim_book, dim_customer, dim_location, dim_shipping_method in parallel)
//   -> DFT fact_sales             (date key, price check, 5 surrogate-key lookups, unknown members)
//   -> SQL Reconcile row counts   (etl.audit; fails the package if any order line is lost)
//   OnError event handler -> 'Failed' row in etl.audit
//
// Build with ssis/tools/build_transform_package.ps1.

using System;
using System.Collections.Generic;
using Microsoft.SqlServer.Dts.Runtime;
using Microsoft.SqlServer.Dts.Pipeline.Wrapper;
using RW = Microsoft.SqlServer.Dts.Runtime.Wrapper;

class BuildTransformPackage
{
    static Application app = new Application();
    static Package pkg;
    const string PackageName = "Transform_Load_DW";

    // A Derived Column expression: either replaces an existing column or adds a new one.
    // Expressions are written with [column] names; they are converted to lineage IDs internally.
    class Spec
    {
        public string Name, Expr; public bool Replace;
        public RW.DataType Type; public int Length, Precision, Scale, CodePage;
        public static Spec ReplaceCol(string name, string expr) { Spec s = new Spec(); s.Name = name; s.Expr = expr; s.Replace = true; return s; }
        public static Spec NewStr(string name, int len, string expr) { Spec s = new Spec(); s.Name = name; s.Expr = expr; s.Type = RW.DataType.DT_STR; s.Length = len; s.CodePage = 1252; return s; }
        public static Spec New(string name, RW.DataType type, string expr) { Spec s = new Spec(); s.Name = name; s.Expr = expr; s.Type = type; return s; }
    }

    static void Main(string[] args)
    {
        string outFile = args[0];

        pkg = new Package();
        pkg.Name = PackageName;
        pkg.Description = "Cleanses the staging data and loads the gravity_dw star schema";
        pkg.ProtectionLevel = DTSProtectionLevel.EncryptSensitiveWithUserKey;

        ConnectionManager stg = AddOleDb("STG_gravity_staging", "gravity_staging");
        ConnectionManager dw  = AddOleDb("DW_gravity_dw", "gravity_dw");

        // ---------- Control flow ----------
        TaskHost sqlDq = AddSql(pkg, "SQL Run data-quality checks", dw, "EXEC dq.usp_run_checks;",
            "Runs the data-quality checks on the staged data and logs the results to dq.check_log");
        TaskHost sqlPrep = AddSql(pkg, "SQL Prepare full load", dw, "EXEC etl.usp_prepare_full_load;",
            "Empties the fact and dimension tables (keeps the -1 unknown members) for a full reload");
        TaskHost sqlDate = AddSql(pkg, "SQL Load dim_date", dw, "EXEC etl.usp_load_dim_date;",
            "Generates the calendar and tags each date as Pre- or Post-campaign");

        Sequence seqDims = (Sequence)pkg.Executables.Add("STOCK:SEQUENCE");
        seqDims.Name = "SEQ Load dimensions";
        seqDims.Description = "Dimensions are independent of each other, so they load in parallel";
        BuildDimBook(seqDims, stg, dw);
        BuildDimCustomer(seqDims, stg, dw);
        BuildDimLocation(seqDims, stg, dw);
        BuildDimShipping(seqDims, stg, dw);

        TaskHost dftFact = BuildFact(pkg, stg, dw);

        TaskHost sqlRecon = AddSql(pkg, "SQL Reconcile row counts", dw, ReconcileSql(),
            "Compares staging and warehouse row counts, logs them to etl.audit and fails the package on a mismatch");

        pkg.PrecedenceConstraints.Add(sqlDq, sqlPrep);
        pkg.PrecedenceConstraints.Add(sqlPrep, sqlDate);
        pkg.PrecedenceConstraints.Add(sqlDate, seqDims);
        pkg.PrecedenceConstraints.Add(seqDims, dftFact);
        pkg.PrecedenceConstraints.Add(dftFact, sqlRecon);

        DtsEventHandler onError = (DtsEventHandler)pkg.EventHandlers.Add("OnError");
        TaskHost sqlFail = AddSql(onError, "SQL Log failure", dw, "SELECT 1", "Logs the failing task to etl.audit");
        sqlFail.SetExpression("SqlStatementSource",
            "\"INSERT INTO etl.audit (package_name, task_name, end_time, status) VALUES ('" + PackageName +
            "', '\" + @[System::SourceName] + \"', SYSDATETIME(), 'Failed')\"");

        Events ev = new Events();
        DTSExecResult r = pkg.Validate(null, null, ev, null);
        Console.WriteLine("Validation: " + r);
        app.SaveToXml(outFile, pkg, null);
        Console.WriteLine("Saved " + outFile);
        if (r != DTSExecResult.Success) Environment.Exit(1);
    }

    // ===================== Dimensions =====================

    static void BuildDimBook(Sequence seq, ConnectionManager stg, ConnectionManager dw)
    {
        MainPipe mp = NewDataFlow(seq, "DFT dim_book", "book + language + publisher -> dim_book");
        IDTSComponentMetaData100 src = AddSource(mp, "SRC book + language + publisher", stg,
            "SELECT b.book_id, CAST(b.title AS VARCHAR(400)) AS title, b.isbn13, b.num_pages, b.publication_date,\r\n" +
            "       CAST(p.publisher_name AS VARCHAR(400)) AS publisher_name, l.language_code, l.language_name\r\n" +
            "FROM stg.book b\r\n" +
            "LEFT JOIN stg.publisher p     ON p.publisher_id = b.publisher_id\r\n" +
            "LEFT JOIN stg.book_language l ON l.language_id  = b.language_id");
        IDTSComponentMetaData100 der = AddDerived(mp, src.OutputCollection[0], "DER Cleanse book", new Spec[] {
            // Leading zeros were lost in the source: pad back to 13 characters
            // (a NULL ISBN stays NULL: string functions return NULL for NULL input)
            Spec.ReplaceCol("isbn13", "(DT_STR,13,1252)RIGHT(\"0000000000000\" + TRIM([isbn13]), 13)"),
            // 0 pages is not a real page count: store as unknown
            Spec.ReplaceCol("num_pages", "[num_pages] <= 0 ? NULL(DT_I4) : [num_pages]"),
            Spec.New("publication_year", RW.DataType.DT_I2, "(DT_I2)YEAR((DT_DBTIMESTAMP)[publication_date])"),
            // 5 English variants -> English; everything else (including 'mul') -> Non-English
            Spec.NewStr("language_group", 20, "(DT_STR,20,1252)(ISNULL([language_code]) ? \"Unknown\" : " +
                "([language_code] == \"eng\" || [language_code] == \"en-US\" || [language_code] == \"en-GB\" || " +
                "[language_code] == \"en-CA\" || [language_code] == \"enm\") ? \"English\" : \"Non-English\")")
        });
        IDTSComponentMetaData100 cnt = AddRowCount(mp, der.OutputCollection[0], "dim_book");
        AddDestination(mp, cnt.OutputCollection[0], "DST dim_book", dw, "[dbo].[dim_book]", null);
    }

    static void BuildDimCustomer(Sequence seq, ConnectionManager stg, ConnectionManager dw)
    {
        MainPipe mp = NewDataFlow(seq, "DFT dim_customer", "customer + survey -> dim_customer");
        IDTSComponentMetaData100 src = AddSource(mp, "SRC customer + survey", stg,
            "SELECT c.customer_id, c.first_name, c.last_name, c.email,\r\n" +
            "       CAST(s.heard_about AS VARCHAR(50)) AS heard_about, CAST(s.preferred_channel AS VARCHAR(50)) AS preferred_channel\r\n" +
            "FROM stg.customer c\r\n" +
            "LEFT JOIN (SELECT TRY_CAST(customer_id AS INT) AS customer_id, heard_about, preferred_channel,\r\n" +
            "                  ROW_NUMBER() OVER (PARTITION BY TRY_CAST(customer_id AS INT) ORDER BY load_datetime) AS rn\r\n" +
            "           FROM stg.survey) s\r\n" +
            "       ON s.customer_id = c.customer_id AND s.rn = 1   -- first response only, if duplicated");
        IDTSComponentMetaData100 der = AddDerived(mp, src.OutputCollection[0], "DER Cleanse customer", new Spec[] {
            Spec.NewStr("full_name", 401, "(DT_STR,401,1252)(TRIM(REPLACENULL([first_name], \"\")) + \" \" + TRIM(REPLACENULL([last_name], \"\")))"),
            Spec.NewStr("email_domain", 200, "(DT_STR,200,1252)(FINDSTRING(REPLACENULL([email], \"\"), \"@\", 1) > 0 ? " +
                "LOWER(RIGHT([email], LEN([email]) - FINDSTRING([email], \"@\", 1))) : \"Unknown\")"),
            Spec.New("survey_responded", RW.DataType.DT_BOOL, "ISNULL([preferred_channel]) ? FALSE : TRIM([preferred_channel]) != \"\""),
            // Customers with no survey row get an explicit label instead of NULL
            Spec.ReplaceCol("heard_about", "(DT_STR,50,1252)(ISNULL([heard_about]) ? \"No response\" : TRIM([heard_about]) == \"\" ? \"No response\" : TRIM([heard_about]))"),
            Spec.ReplaceCol("preferred_channel", "(DT_STR,50,1252)(ISNULL([preferred_channel]) ? \"No response\" : TRIM([preferred_channel]) == \"\" ? \"No response\" : TRIM([preferred_channel]))")
        });
        IDTSComponentMetaData100 cnt = AddRowCount(mp, der.OutputCollection[0], "dim_customer");
        AddDestination(mp, cnt.OutputCollection[0], "DST dim_customer", dw, "[dbo].[dim_customer]", null);
    }

    static void BuildDimLocation(Sequence seq, ConnectionManager stg, ConnectionManager dw)
    {
        MainPipe mp = NewDataFlow(seq, "DFT dim_location", "address + country + country_region -> dim_location");
        IDTSComponentMetaData100 src = AddSource(mp, "SRC address + country", stg,
            "SELECT a.address_id, a.street_number, a.street_name, a.city, a.country_id,\r\n" +
            "       CAST(c.country_name AS VARCHAR(200)) AS source_country_name\r\n" +
            "FROM stg.address a\r\n" +
            "LEFT JOIN stg.country c ON c.country_id = a.country_id");
        // Reference data: cleansed country name, continent and status (Current / Historical / Invalid)
        IDTSComponentMetaData100 lkp = AddLookup(mp, src.OutputCollection[0], "LKP country_region", stg,
            "SELECT TRY_CAST(country_id AS INT) AS country_id, CAST(clean_country_name AS VARCHAR(200)) AS clean_country_name,\r\n" +
            "       CAST(region AS VARCHAR(50)) AS region, CAST(country_status AS VARCHAR(20)) AS country_status\r\n" +
            "FROM stg.country_region",
            "country_id", "country_id",
            new string[] { "clean_country_name", "region", "country_status" },
            new RW.DataType[] { RW.DataType.DT_STR, RW.DataType.DT_STR, RW.DataType.DT_STR },
            new int[] { 200, 50, 20 });
        IDTSComponentMetaData100 der = AddDerived(mp, MatchOutput(lkp), "DER Conform country", new Spec[] {
            // Fixes 'Boliva', merges the two Singapores, maps historical states to modern successors
            Spec.NewStr("country_name", 200, "(DT_STR,200,1252)REPLACENULL([clean_country_name], REPLACENULL([source_country_name], \"Unknown\"))"),
            Spec.ReplaceCol("region", "(DT_STR,50,1252)REPLACENULL([region], \"Unknown\")"),
            Spec.ReplaceCol("country_status", "(DT_STR,20,1252)REPLACENULL([country_status], \"Unknown\")"),
            Spec.ReplaceCol("city", "(DT_STR,100,1252)REPLACENULL(TRIM([city]), \"Unknown\")")
        });
        IDTSComponentMetaData100 cnt = AddRowCount(mp, der.OutputCollection[0], "dim_location");
        AddDestination(mp, cnt.OutputCollection[0], "DST dim_location", dw, "[dbo].[dim_location]", null);
    }

    static void BuildDimShipping(Sequence seq, ConnectionManager stg, ConnectionManager dw)
    {
        MainPipe mp = NewDataFlow(seq, "DFT dim_shipping_method", "shipping_method -> dim_shipping_method");
        IDTSComponentMetaData100 src = AddSource(mp, "SRC shipping_method", stg,
            "SELECT method_id, method_name, cost FROM stg.shipping_method");
        IDTSComponentMetaData100 cnt = AddRowCount(mp, src.OutputCollection[0], "dim_shipping_method");
        AddDestination(mp, cnt.OutputCollection[0], "DST dim_shipping_method", dw, "[dbo].[dim_shipping_method]", null);
    }

    // ===================== Fact =====================

    static TaskHost BuildFact(IDTSSequence parent, ConnectionManager stg, ConnectionManager dw)
    {
        TaskHost th = (TaskHost)parent.Executables.Add("STOCK:PipelineTask");
        th.Name = "DFT fact_sales";
        th.Description = "Order lines -> fact_sales (grain: one row per order line)";
        MainPipe mp = (MainPipe)th.InnerObject;

        IDTSComponentMetaData100 src = AddSource(mp, "SRC order lines + orders + latest status", stg,
            "SELECT ol.line_id, ol.order_id, ol.book_id, o.customer_id, o.dest_address_id, o.shipping_method_id, o.order_date,\r\n" +
            "       CAST(ol.price AS DECIMAL(7,2)) AS sales_amount,\r\n" +
            "       CAST(COALESCE(st.status_value, 'Unknown') AS VARCHAR(20)) AS latest_order_status,\r\n" +
            "       CAST(CASE WHEN EXISTS (SELECT 1 FROM stg.order_history h\r\n" +
            "                              WHERE h.order_id = ol.order_id AND h.status_id IN (5, 6))  -- Cancelled / Returned\r\n" +
            "                 THEN 1 ELSE 0 END AS BIT) AS is_cancelled_or_returned\r\n" +
            "FROM stg.order_line ol\r\n" +
            "LEFT JOIN stg.cust_order o ON o.order_id = ol.order_id\r\n" +
            "OUTER APPLY (SELECT TOP (1) h.status_id FROM stg.order_history h\r\n" +
            "             WHERE h.order_id = ol.order_id ORDER BY h.status_date DESC, h.history_id DESC) lh\r\n" +
            "LEFT JOIN stg.order_status st ON st.status_id = lh.status_id");

        IDTSComponentMetaData100 derDate = AddDerived(mp, src.OutputCollection[0], "DER Date key", new Spec[] {
            Spec.New("order_date_int", RW.DataType.DT_I4,
                "ISNULL([order_date]) ? -1 : (DT_I4)(YEAR([order_date]) * 10000 + MONTH([order_date]) * 100 + DAY([order_date]))")
        });

        // Invalid prices go to the reject table; everything else continues
        IDTSOutput100 rejectOut, validOut;
        AddPriceSplit(mp, derDate.OutputCollection[0], out rejectOut, out validOut);

        IDTSComponentMetaData100 derReason = AddDerived(mp, rejectOut, "DER Reject reason", new Spec[] {
            Spec.NewStr("reject_reason", 200, "(DT_STR,200,1252)(ISNULL([sales_amount]) ? \"Missing price\" : \"Price zero or negative\")")
        });
        IDTSComponentMetaData100 cntRej = AddRowCount(mp, derReason.OutputCollection[0], "fact_rejects");
        Dictionary<string, string> rejMap = new Dictionary<string, string>();
        rejMap["sales_amount"] = "price";
        AddDestination(mp, cntRej.OutputCollection[0], "DST dq_fact_rejects", dw, "[dq].[fact_rejects]", rejMap);

        // Surrogate-key lookups (full cache). No match -> NULL -> unknown member -1 further down.
        RW.DataType[] i4 = { RW.DataType.DT_I4 }; int[] z = { 0 };
        IDTSComponentMetaData100 lkDate = AddLookup(mp, validOut, "LKP dim_date", dw,
            "SELECT date_key FROM dbo.dim_date WHERE date_key <> -1", "order_date_int", "date_key",
            new string[] { "date_key" }, i4, z, new string[] { "order_date_key" });
        IDTSComponentMetaData100 lkCust = AddLookup(mp, MatchOutput(lkDate), "LKP dim_customer", dw,
            "SELECT customer_key, customer_id FROM dbo.dim_customer WHERE customer_key <> -1", "customer_id", "customer_id",
            new string[] { "customer_key" }, i4, z);
        IDTSComponentMetaData100 lkBook = AddLookup(mp, MatchOutput(lkCust), "LKP dim_book", dw,
            "SELECT book_key, book_id FROM dbo.dim_book WHERE book_key <> -1", "book_id", "book_id",
            new string[] { "book_key" }, i4, z);
        IDTSComponentMetaData100 lkLoc = AddLookup(mp, MatchOutput(lkBook), "LKP dim_location", dw,
            "SELECT location_key, address_id FROM dbo.dim_location WHERE location_key <> -1", "dest_address_id", "address_id",
            new string[] { "location_key" }, i4, z);
        IDTSComponentMetaData100 lkShip = AddLookup(mp, MatchOutput(lkLoc), "LKP dim_shipping_method", dw,
            "SELECT shipping_key, method_id FROM dbo.dim_shipping_method WHERE shipping_key <> -1", "shipping_method_id", "method_id",
            new string[] { "shipping_key" }, i4, z);

        IDTSComponentMetaData100 derUnknown = AddDerived(mp, MatchOutput(lkShip), "DER Unknown members", new Spec[] {
            Spec.ReplaceCol("order_date_key", "REPLACENULL([order_date_key], -1)"),
            Spec.ReplaceCol("customer_key",   "REPLACENULL([customer_key], -1)"),
            Spec.ReplaceCol("book_key",       "REPLACENULL([book_key], -1)"),
            Spec.ReplaceCol("location_key",   "REPLACENULL([location_key], -1)"),
            Spec.ReplaceCol("shipping_key",   "REPLACENULL([shipping_key], -1)")
        });
        IDTSComponentMetaData100 cnt = AddRowCount(mp, derUnknown.OutputCollection[0], "fact_sales");
        AddDestination(mp, cnt.OutputCollection[0], "DST fact_sales", dw, "[dbo].[fact_sales]", null);
        return th;
    }

    static void AddPriceSplit(MainPipe mp, IDTSOutput100 upOut, out IDTSOutput100 rejectOut, out IDTSOutput100 validOut)
    {
        CManagedComponentWrapper inst;
        IDTSComponentMetaData100 cs = NewComponent(mp, "Conditional Split", "CSPL Validate price", out inst);
        Connect(mp, upOut, cs);
        IDTSInput100 input = cs.InputCollection[0];
        IDTSVirtualInput100 vin = input.GetVirtualInput();
        string friendly = "ISNULL([sales_amount]) || [sales_amount] <= 0";
        UseColumns(inst, input, vin, new string[] { friendly }, null);

        IDTSOutput100 def = null;
        foreach (IDTSOutput100 o in cs.OutputCollection) if (!o.IsErrorOut) def = o;
        IDTSOutput100 bad = inst.InsertOutput(DTSInsertPlacement.IP_BEFORE, def.ID);
        bad.Name = "Invalid price";
        inst.SetOutputProperty(bad.ID, "EvaluationOrder", 0);
        inst.SetOutputProperty(bad.ID, "Expression", ToLineage(friendly, vin));
        inst.SetOutputProperty(bad.ID, "FriendlyExpression", friendly);
        def.Name = "Valid";
        rejectOut = bad;
        validOut = def;
    }

    static string ReconcileSql()
    {
        return
"DECLARE @run DATETIME2 = SYSDATETIME();\r\n" +
"INSERT INTO etl.audit (package_name, task_name, table_name, rows_read, rows_written, rows_rejected, start_time, end_time, status)\r\n" +
"SELECT '" + PackageName + "', 'Reconcile', table_name, rows_read, rows_written, rows_rejected, @run, SYSDATETIME(),\r\n" +
"       CASE WHEN rows_read = rows_written + rows_rejected THEN 'Success' ELSE 'Mismatch' END\r\n" +
"FROM (VALUES\r\n" +
"  ('dbo.dim_book',            (SELECT COUNT(*) FROM gravity_staging.stg.book),            (SELECT COUNT(*) FROM dbo.dim_book WHERE book_key <> -1), 0),\r\n" +
"  ('dbo.dim_customer',        (SELECT COUNT(*) FROM gravity_staging.stg.customer),        (SELECT COUNT(*) FROM dbo.dim_customer WHERE customer_key <> -1), 0),\r\n" +
"  ('dbo.dim_location',        (SELECT COUNT(*) FROM gravity_staging.stg.address),         (SELECT COUNT(*) FROM dbo.dim_location WHERE location_key <> -1), 0),\r\n" +
"  ('dbo.dim_shipping_method', (SELECT COUNT(*) FROM gravity_staging.stg.shipping_method), (SELECT COUNT(*) FROM dbo.dim_shipping_method WHERE shipping_key <> -1), 0),\r\n" +
"  ('dbo.dim_date', (SELECT DATEDIFF(DAY, MIN(CASE WHEN config_key = 'dim_date_start' THEN CAST(config_value AS DATE) END),\r\n" +
"                                     MAX(CASE WHEN config_key = 'dim_date_end' THEN CAST(config_value AS DATE) END)) + 1 FROM etl.config),\r\n" +
"                   (SELECT COUNT(*) FROM dbo.dim_date WHERE date_key <> -1), 0),\r\n" +
"  ('dbo.fact_sales', (SELECT COUNT(*) FROM gravity_staging.stg.order_line), (SELECT COUNT(*) FROM dbo.fact_sales), (SELECT COUNT(*) FROM dq.fact_rejects))\r\n" +
") v (table_name, rows_read, rows_written, rows_rejected);\r\n" +
"\r\n" +
"IF EXISTS (SELECT 1 FROM etl.audit WHERE package_name = '" + PackageName + "' AND start_time = @run AND status = 'Mismatch')\r\n" +
"    THROW 50001, 'Row count reconciliation failed: see etl.audit', 1;";
    }

    // ===================== helpers =====================

    static ConnectionManager AddOleDb(string name, string db)
    {
        ConnectionManager cm = pkg.Connections.Add("OLEDB");
        cm.Name = name;
        cm.ConnectionString = "Data Source=localhost;Initial Catalog=" + db +
            ";Provider=MSOLEDBSQL19.1;Integrated Security=SSPI;Use Encryption for Data=Optional;" +
            "Trust Server Certificate=True;Auto Translate=False;Application Name=GravityETL;";
        return cm;
    }

    static TaskHost AddSql(IDTSSequence parent, string name, ConnectionManager cm, string sql, string description)
    {
        TaskHost th = (TaskHost)parent.Executables.Add("STOCK:SQLTask");
        th.Name = name;
        th.Description = description;
        th.Properties["Connection"].SetValue(th, cm.ID);
        th.Properties["SqlStatementSource"].SetValue(th, sql);
        return th;
    }

    static MainPipe NewDataFlow(IDTSSequence parent, string name, string description)
    {
        TaskHost th = (TaskHost)parent.Executables.Add("STOCK:PipelineTask");
        th.Name = name;
        th.Description = description;
        return (MainPipe)th.InnerObject;
    }

    static string ProgId(string componentName)
    {
        foreach (PipelineComponentInfo info in app.PipelineComponentInfos)
            if (info.Name == componentName) return info.CreationName;
        throw new Exception("SSIS component not found: " + componentName);
    }

    static IDTSComponentMetaData100 NewComponent(MainPipe mp, string type, string name, out CManagedComponentWrapper inst)
    {
        IDTSComponentMetaData100 c = mp.ComponentMetaDataCollection.New();
        c.ComponentClassID = ProgId(type);
        inst = c.Instantiate();
        inst.ProvideComponentProperties();
        c.Name = name;
        return c;
    }

    static void UseConnection(IDTSComponentMetaData100 c, ConnectionManager cm)
    {
        c.RuntimeConnectionCollection[0].ConnectionManager = DtsConvert.GetExtendedInterface(cm);
        c.RuntimeConnectionCollection[0].ConnectionManagerID = cm.ID;
    }

    static void Refresh(CManagedComponentWrapper inst)
    {
        inst.AcquireConnections(null);
        inst.ReinitializeMetaData();
        inst.ReleaseConnections();
    }

    static void Connect(MainPipe mp, IDTSOutput100 from, IDTSComponentMetaData100 to)
    {
        IDTSPath100 p = mp.PathCollection.New();
        p.AttachPathAndPropagateNotifications(from, to.InputCollection[0]);
    }

    static IDTSOutput100 MatchOutput(IDTSComponentMetaData100 lookup)
    {
        foreach (IDTSOutput100 o in lookup.OutputCollection)
            if (!o.IsErrorOut && o.Name.IndexOf("No Match", StringComparison.OrdinalIgnoreCase) < 0) return o;
        throw new Exception("No match output on " + lookup.Name);
    }

    // Replaces [column] references with #lineageID, as stored in the package
    static string ToLineage(string expr, IDTSVirtualInput100 vin)
    {
        foreach (IDTSVirtualInputColumn100 vc in vin.VirtualInputColumnCollection)
            expr = expr.Replace("[" + vc.Name + "]", "#" + vc.LineageID);
        return expr;
    }

    // Adds every column referenced in the expressions to the component input
    static void UseColumns(CManagedComponentWrapper inst, IDTSInput100 input, IDTSVirtualInput100 vin, string[] exprs, ICollection<string> readWrite)
    {
        foreach (IDTSVirtualInputColumn100 vc in vin.VirtualInputColumnCollection)
        {
            bool rw = readWrite != null && readWrite.Contains(vc.Name);
            bool used = rw;
            foreach (string e in exprs) if (e.Contains("[" + vc.Name + "]")) used = true;
            if (used) inst.SetUsageType(input.ID, vin, vc.LineageID, rw ? DTSUsageType.UT_READWRITE : DTSUsageType.UT_READONLY);
        }
    }

    static IDTSComponentMetaData100 AddSource(MainPipe mp, string name, ConnectionManager cm, string sql)
    {
        CManagedComponentWrapper inst;
        IDTSComponentMetaData100 s = NewComponent(mp, "OLE DB Source", name, out inst);
        UseConnection(s, cm);
        inst.SetComponentProperty("AccessMode", 2);   // SQL command
        inst.SetComponentProperty("SqlCommand", sql);
        Refresh(inst);
        return s;
    }

    static IDTSComponentMetaData100 AddDerived(MainPipe mp, IDTSOutput100 upOut, string name, Spec[] specs)
    {
        CManagedComponentWrapper inst;
        IDTSComponentMetaData100 dc = NewComponent(mp, "Derived Column", name, out inst);
        Connect(mp, upOut, dc);
        IDTSInput100 input = dc.InputCollection[0];
        IDTSVirtualInput100 vin = input.GetVirtualInput();

        List<string> exprs = new List<string>(); List<string> replaced = new List<string>();
        foreach (Spec s in specs) { exprs.Add(s.Expr); if (s.Replace) replaced.Add(s.Name); }
        UseColumns(inst, input, vin, exprs.ToArray(), replaced);

        IDTSOutput100 output = dc.OutputCollection[0];
        foreach (Spec s in specs)
        {
            string lineage = ToLineage(s.Expr, vin);
            try {
            if (s.Replace)
            {
                IDTSInputColumn100 ic = null;
                foreach (IDTSInputColumn100 c in input.InputColumnCollection) if (c.Name == s.Name) ic = c;
                if (ic == null) throw new Exception(name + ": no column " + s.Name + " to replace");
                inst.SetInputColumnProperty(input.ID, ic.ID, "Expression", lineage);
                inst.SetInputColumnProperty(input.ID, ic.ID, "FriendlyExpression", s.Expr);
            }
            else
            {
                IDTSOutputColumn100 oc = inst.InsertOutputColumnAt(output.ID, output.OutputColumnCollection.Count, s.Name, "");
                inst.SetOutputColumnDataTypeProperties(output.ID, oc.ID, s.Type, s.Length, s.Precision, s.Scale, s.CodePage);
                inst.SetOutputColumnProperty(output.ID, oc.ID, "Expression", lineage);
                inst.SetOutputColumnProperty(output.ID, oc.ID, "FriendlyExpression", s.Expr);
            }
            } catch (Exception ex) {
                throw new Exception(name + ": expression for '" + s.Name + "' was rejected (" + ex.Message + "): " + s.Expr, ex);
            }
        }
        return dc;
    }

    // Full-cache lookup; rows with no match continue with NULL in the copied columns (Ignore failure)
    static IDTSComponentMetaData100 AddLookup(MainPipe mp, IDTSOutput100 upOut, string name, ConnectionManager cm, string sql,
        string inputCol, string refJoinCol, string[] copyCols, RW.DataType[] types, int[] lengths)
    {
        return AddLookup(mp, upOut, name, cm, sql, inputCol, refJoinCol, copyCols, types, lengths, copyCols);
    }

    static IDTSComponentMetaData100 AddLookup(MainPipe mp, IDTSOutput100 upOut, string name, ConnectionManager cm, string sql,
        string inputCol, string refJoinCol, string[] copyCols, RW.DataType[] types, int[] lengths, string[] outNames)
    {
        CManagedComponentWrapper inst;
        IDTSComponentMetaData100 lk = NewComponent(mp, "Lookup", name, out inst);
        UseConnection(lk, cm);
        inst.SetComponentProperty("CacheType", 0);          // full cache
        inst.SetComponentProperty("SqlCommand", sql);
        Connect(mp, upOut, lk);
        Refresh(inst);

        IDTSInput100 input = lk.InputCollection[0];
        IDTSVirtualInput100 vin = input.GetVirtualInput();
        IDTSVirtualInputColumn100 join = null;
        foreach (IDTSVirtualInputColumn100 vc in vin.VirtualInputColumnCollection) if (vc.Name == inputCol) join = vc;
        if (join == null) throw new Exception(name + ": no input column " + inputCol);
        IDTSInputColumn100 ic = inst.SetUsageType(input.ID, vin, join.LineageID, DTSUsageType.UT_READONLY);
        inst.SetInputColumnProperty(input.ID, ic.ID, "JoinToReferenceColumn", refJoinCol);
        IDTSOutput100 match = MatchOutput(lk);
        // The Lookup keeps its no-match handling on the Match output (not the input):
        // Ignore failure = rows with no match continue with NULL in the copied columns
        match.ErrorRowDisposition = DTSRowDisposition.RD_IgnoreFailure;
        for (int i = 0; i < copyCols.Length; i++)
        {
            IDTSOutputColumn100 oc = inst.InsertOutputColumnAt(match.ID, i, outNames[i], "");
            oc.SetDataTypeProperties(types[i], lengths[i], 0, 0, types[i] == RW.DataType.DT_STR ? 1252 : 0);
            inst.SetOutputColumnProperty(match.ID, oc.ID, "CopyFromReferenceColumn", copyCols[i]);
        }
        return lk;
    }

    static IDTSComponentMetaData100 AddRowCount(MainPipe mp, IDTSOutput100 upOut, string table)
    {
        string var = "Rows_" + table;
        if (!pkg.Variables.Contains("User::" + var)) pkg.Variables.Add(var, false, "User", 0);
        CManagedComponentWrapper inst;
        IDTSComponentMetaData100 rc = NewComponent(mp, "Row Count", "CNT " + table, out inst);
        inst.SetComponentProperty("VariableName", "User::" + var);
        Connect(mp, upOut, rc);
        return rc;
    }

    // OLE DB destination, fast load. Columns map by name unless renamed in 'map'.
    // Identity keys and columns with defaults (e.g. quantity) are left unmapped.
    static void AddDestination(MainPipe mp, IDTSOutput100 upOut, string name, ConnectionManager cm, string table, Dictionary<string, string> map)
    {
        CManagedComponentWrapper inst;
        IDTSComponentMetaData100 d = NewComponent(mp, "OLE DB Destination", name, out inst);
        UseConnection(d, cm);
        inst.SetComponentProperty("AccessMode", 3);
        inst.SetComponentProperty("OpenRowset", table);
        inst.SetComponentProperty("FastLoadKeepNulls", false);  // so unmapped columns get their DEFAULT
        inst.SetComponentProperty("FastLoadOptions", "TABLOCK,CHECK_CONSTRAINTS");
        Refresh(inst);
        Connect(mp, upOut, d);

        IDTSInput100 input = d.InputCollection[0];
        IDTSVirtualInput100 vin = input.GetVirtualInput();
        foreach (IDTSVirtualInputColumn100 vc in vin.VirtualInputColumnCollection)
        {
            string target = (map != null && map.ContainsKey(vc.Name)) ? map[vc.Name] : vc.Name;
            foreach (IDTSExternalMetadataColumn100 ext in input.ExternalMetadataColumnCollection)
            {
                if (string.Equals(ext.Name, target, StringComparison.OrdinalIgnoreCase))
                {
                    IDTSInputColumn100 ic = inst.SetUsageType(input.ID, vin, vc.LineageID, DTSUsageType.UT_READONLY);
                    inst.MapInputColumn(input.ID, ic.ID, ext.ID);
                    break;
                }
            }
        }
    }

    class Events : DefaultEvents
    {
        public override bool OnError(DtsObject source, int errorCode, string subComponent, string description, string helpFile, int helpContext, string idofInterfaceWithError)
        {
            Console.WriteLine("ERROR  [" + subComponent + "] " + description);
            return false;
        }
        public override void OnWarning(DtsObject source, int warningCode, string subComponent, string description, string helpFile, int helpContext, string idofInterfaceWithError)
        {
            Console.WriteLine("WARN   [" + subComponent + "] " + description);
        }
    }
}
