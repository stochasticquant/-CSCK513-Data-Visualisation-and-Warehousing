// BuildExtractPackage.cs
// Generates the SSIS package Extract_To_Staging.dtsx with the SSIS object model
// (SQL Server 2025 / SSIS 17). Its layout follows docs/SSIS_Package1_Extract_Guide.md:
//
//   SQL Truncate staging tables
//     -> SEQ Extract OLTP   (11 data flows in parallel: OLE DB Source -> Row Count -> OLE DB Destination)
//     -> SEQ Extract files  (survey CSV with a TRIM Derived Column, country_region CSV)
//     -> SQL Log row counts (writes one row per staging table to gravity_dw.etl.audit)
//   OnError event handler -> writes a 'Failed' row to etl.audit
//
// Build and run with ssis/tools/build_extract_package.ps1.

using System;
using Microsoft.SqlServer.Dts.Runtime;
using Microsoft.SqlServer.Dts.Pipeline.Wrapper;
using RW = Microsoft.SqlServer.Dts.Runtime.Wrapper;

class BuildExtractPackage
{
    static Application app = new Application();
    static Package pkg;

    static void Main(string[] args)
    {
        string root = args[0];      // the "Module 4" folder
        string outFile = args[1];   // where to save the .dtsx

        pkg = new Package();
        pkg.Name = "Extract_To_Staging";
        pkg.Description = "Extracts gravity_books and the two CSV files into gravity_staging";
        pkg.ProtectionLevel = DTSProtectionLevel.EncryptSensitiveWithUserKey;

        // ---------- Connection managers ----------
        ConnectionManager src = AddOleDb("SRC_gravity_books", "gravity_books");
        ConnectionManager stg = AddOleDb("STG_gravity_staging", "gravity_staging");
        ConnectionManager dw  = AddOleDb("DW_gravity_dw", "gravity_dw");

        ConnectionManager ffSurvey = AddFlatFile("FF_Survey", root + @"\bookstore survey.csv",
            new string[] { "customer_id", "heard_about", "preferred_channel" },
            new int[]    { 50, 100, 100 });
        ConnectionManager ffRegion = AddFlatFile("FF_CountryRegion", root + @"\reference\country_region.csv",
            new string[] { "country_id", "country_name", "clean_country_name", "region", "country_status", "cleansing_note" },
            new int[]    { 10, 200, 200, 50, 20, 200 });

        // ---------- Control flow ----------
        string[] stgTables = { "book", "book_language", "publisher", "customer", "address", "country",
                               "cust_order", "order_line", "order_history", "order_status",
                               "shipping_method", "survey", "country_region" };

        string truncate = "";
        foreach (string t in stgTables) truncate += "TRUNCATE TABLE stg." + t + ";\r\n";
        TaskHost sqlTruncate = AddSql(pkg, "SQL Truncate staging tables", stg, truncate,
            "Empties every staging table so the package can be re-run without duplicating rows");

        Sequence seqOltp = (Sequence)pkg.Executables.Add("STOCK:SEQUENCE");
        seqOltp.Name = "SEQ Extract OLTP";
        seqOltp.Description = "One data flow per source table. No links between them, so they run in parallel";

        string[,] oltp = {
            { "book",            "SELECT book_id, title, isbn13, language_id, num_pages, publication_date, publisher_id FROM dbo.book" },
            { "book_language",   "SELECT language_id, language_code, language_name FROM dbo.book_language" },
            { "publisher",       "SELECT publisher_id, publisher_name FROM dbo.publisher" },
            { "customer",        "SELECT customer_id, first_name, last_name, email FROM dbo.customer" },
            { "address",         "SELECT address_id, street_number, street_name, city, country_id FROM dbo.address" },
            { "country",         "SELECT country_id, country_name FROM dbo.country" },
            { "cust_order",      "SELECT order_id, order_date, customer_id, shipping_method_id, dest_address_id FROM dbo.cust_order" },
            { "order_line",      "SELECT line_id, order_id, book_id, price FROM dbo.order_line" },
            { "order_history",   "SELECT history_id, order_id, status_id, status_date FROM dbo.order_history" },
            { "order_status",    "SELECT status_id, status_value FROM dbo.order_status" },
            { "shipping_method", "SELECT method_id, method_name, cost FROM dbo.shipping_method" } };
        for (int i = 0; i < oltp.GetLength(0); i++)
            AddTableCopy(seqOltp, oltp[i, 0], oltp[i, 1], src, stg);

        Sequence seqFiles = (Sequence)pkg.Executables.Add("STOCK:SEQUENCE");
        seqFiles.Name = "SEQ Extract files";
        seqFiles.Description = "Loads the survey and the country/region reference CSV files";
        AddFileLoad(seqFiles, "survey", ffSurvey, stg, true);
        AddFileLoad(seqFiles, "country_region", ffRegion, stg, false);

        string audit = "INSERT INTO etl.audit (package_name, task_name, table_name, rows_written, end_time, status)\r\n" +
                       "SELECT 'Extract_To_Staging', 'Extract', table_name, row_count, SYSDATETIME(), 'Success'\r\nFROM (\r\n";
        for (int i = 0; i < stgTables.Length; i++)
            audit += (i == 0 ? "      " : "UNION ALL ") + "SELECT 'stg." + stgTables[i] + "' AS table_name, COUNT(*) AS row_count FROM gravity_staging.stg." + stgTables[i] + "\r\n";
        audit += ") counts;";
        TaskHost sqlAudit = AddSql(pkg, "SQL Log row counts", dw, audit,
            "Writes the row count of every staging table to gravity_dw.etl.audit");

        pkg.PrecedenceConstraints.Add(sqlTruncate, seqOltp);
        pkg.PrecedenceConstraints.Add(seqOltp, seqFiles);
        pkg.PrecedenceConstraints.Add(seqFiles, sqlAudit);

        // ---------- OnError: log the failing task ----------
        DtsEventHandler onError = (DtsEventHandler)pkg.EventHandlers.Add("OnError");
        TaskHost sqlFail = AddSql(onError, "SQL Log failure", dw, "SELECT 1", "Logs the failing task to etl.audit");
        sqlFail.SetExpression("SqlStatementSource",
            "\"INSERT INTO etl.audit (package_name, task_name, end_time, status) VALUES ('Extract_To_Staging', '\" + @[System::SourceName] + \"', SYSDATETIME(), 'Failed')\"");

        // ---------- Validate and save ----------
        Events ev = new Events();
        DTSExecResult r = pkg.Validate(null, null, ev, null);
        Console.WriteLine("Validation: " + r);
        app.SaveToXml(outFile, pkg, null);
        Console.WriteLine("Saved " + outFile);
        if (r != DTSExecResult.Success) Environment.Exit(1);
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

    static ConnectionManager AddFlatFile(string name, string path, string[] cols, int[] widths)
    {
        ConnectionManager cm = pkg.Connections.Add("FLATFILE");
        cm.Name = name;
        cm.ConnectionString = path;
        cm.Properties["Format"].SetValue(cm, "Delimited");
        cm.Properties["ColumnNamesInFirstDataRow"].SetValue(cm, true);
        cm.Properties["TextQualifier"].SetValue(cm, "\"");
        cm.Properties["CodePage"].SetValue(cm, 1252);
        cm.Properties["HeaderRowDelimiter"].SetValue(cm, "\r\n");

        RW.IDTSConnectionManagerFlatFile100 ff = (RW.IDTSConnectionManagerFlatFile100)cm.InnerObject;
        for (int i = 0; i < cols.Length; i++)
        {
            RW.IDTSConnectionManagerFlatFileColumn100 c = ff.Columns.Add();
            c.ColumnType = "Delimited";
            c.ColumnDelimiter = (i == cols.Length - 1) ? "\r\n" : ",";
            c.DataType = RW.DataType.DT_STR;     // VARCHAR in staging, so non-Unicode
            c.MaximumWidth = widths[i];
            c.TextQualified = true;
            ((RW.IDTSName100)c).Name = cols[i];
        }
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

    static void Connect(MainPipe mp, IDTSComponentMetaData100 from, IDTSComponentMetaData100 to)
    {
        IDTSPath100 p = mp.PathCollection.New();
        p.AttachPathAndPropagateNotifications(from.OutputCollection[0], to.InputCollection[0]);
    }

    static IDTSComponentMetaData100 AddRowCount(MainPipe mp, string table)
    {
        string var = "Rows_" + table;
        if (!pkg.Variables.Contains("User::" + var)) pkg.Variables.Add(var, false, "User", 0);
        CManagedComponentWrapper inst;
        IDTSComponentMetaData100 rc = NewComponent(mp, "Row Count", "CNT " + table, out inst);
        inst.SetComponentProperty("VariableName", "User::" + var);
        return rc;
    }

    // OLE DB destination (fast load) with columns mapped by name; load_datetime is left to its default
    static void AddDestination(MainPipe mp, IDTSComponentMetaData100 upstream, string table, ConnectionManager stg)
    {
        CManagedComponentWrapper inst;
        IDTSComponentMetaData100 d = NewComponent(mp, "OLE DB Destination", "DST stg_" + table, out inst);
        UseConnection(d, stg);
        inst.SetComponentProperty("AccessMode", 3);                 // table or view - fast load
        inst.SetComponentProperty("OpenRowset", "[stg].[" + table + "]");
        // KeepNulls must stay OFF: with it on, the bulk insert writes NULL into the unmapped
        // load_datetime column instead of applying its DEFAULT. Source NULLs still arrive as NULL,
        // because no other staging column has a default.
        inst.SetComponentProperty("FastLoadKeepNulls", false);
        inst.SetComponentProperty("FastLoadOptions", "TABLOCK");
        Refresh(inst);
        Connect(mp, upstream, d);

        IDTSInput100 input = d.InputCollection[0];
        IDTSVirtualInput100 vin = input.GetVirtualInput();
        foreach (IDTSVirtualInputColumn100 vc in vin.VirtualInputColumnCollection)
        {
            foreach (IDTSExternalMetadataColumn100 ext in input.ExternalMetadataColumnCollection)
            {
                if (string.Equals(ext.Name, vc.Name, StringComparison.OrdinalIgnoreCase))
                {
                    IDTSInputColumn100 ic = inst.SetUsageType(input.ID, vin, vc.LineageID, DTSUsageType.UT_READONLY);
                    inst.MapInputColumn(input.ID, ic.ID, ext.ID);
                    break;
                }
            }
        }
    }

    static void AddTableCopy(Sequence seq, string table, string sql, ConnectionManager src, ConnectionManager stg)
    {
        TaskHost th = (TaskHost)seq.Executables.Add("STOCK:PipelineTask");
        th.Name = "DFT " + table;
        th.Description = "Copies dbo." + table + " to stg." + table;
        MainPipe mp = (MainPipe)th.InnerObject;

        CManagedComponentWrapper si;
        IDTSComponentMetaData100 s = NewComponent(mp, "OLE DB Source", "SRC " + table, out si);
        UseConnection(s, src);
        si.SetComponentProperty("AccessMode", 2);                   // SQL command
        si.SetComponentProperty("SqlCommand", sql);
        Refresh(si);

        IDTSComponentMetaData100 rc = AddRowCount(mp, table);
        Connect(mp, s, rc);
        AddDestination(mp, rc, table, stg);
    }

    static void AddFileLoad(Sequence seq, string table, ConnectionManager ff, ConnectionManager stg, bool trim)
    {
        TaskHost th = (TaskHost)seq.Executables.Add("STOCK:PipelineTask");
        th.Name = "DFT " + table;
        th.Description = "Loads " + ff.Name + " into stg." + table;
        MainPipe mp = (MainPipe)th.InnerObject;

        CManagedComponentWrapper si;
        IDTSComponentMetaData100 s = NewComponent(mp, "Flat File Source", "FF " + table, out si);
        UseConnection(s, ff);
        Refresh(si);
        IDTSComponentMetaData100 last = s;

        if (trim)
        {
            // Derived Column: replace each column with a trimmed copy (first cleansing step).
            // The (DT_STR,n,1252) cast keeps the result non-Unicode, matching the VARCHAR staging columns.
            CManagedComponentWrapper di;
            IDTSComponentMetaData100 dc = NewComponent(mp, "Derived Column", "DER Trim values", out di);
            Connect(mp, s, dc);
            IDTSInput100 input = dc.InputCollection[0];
            IDTSVirtualInput100 vin = input.GetVirtualInput();
            foreach (IDTSVirtualInputColumn100 vc in vin.VirtualInputColumnCollection)
            {
                IDTSInputColumn100 ic = di.SetUsageType(input.ID, vin, vc.LineageID, DTSUsageType.UT_READWRITE);
                string cast = "(DT_STR," + vc.Length + ",1252)";
                di.SetInputColumnProperty(input.ID, ic.ID, "Expression", cast + "TRIM(#" + vc.LineageID + ")");
                di.SetInputColumnProperty(input.ID, ic.ID, "FriendlyExpression", cast + "TRIM([" + vc.Name + "])");
            }
            last = dc;
        }

        IDTSComponentMetaData100 rc = AddRowCount(mp, table);
        Connect(mp, last, rc);
        AddDestination(mp, rc, table, stg);
    }

    // Prints validation messages
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
