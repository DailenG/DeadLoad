using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace DeadLoad.Tray
{
    /// <summary>
    /// Read-only window over last-run.json: the key fields first for the user, the raw JSON below
    /// for whoever supports them. Nothing here can change the report.
    /// </summary>
    internal sealed class ReportForm : Form
    {
        public ReportForm(LastRunReport report, string error)
        {
            Text = "DeadLoad - last cleanup report";
            StartPosition = FormStartPosition.CenterScreen;
            Size = new Size(640, 560);
            MinimumSize = new Size(420, 360);
            ShowInTaskbar = true;
            Font = SystemFonts.MessageBoxFont;
            AutoScaleMode = AutoScaleMode.Dpi;

            var layout = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = 3,
                Padding = new Padding(8),
            };
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 45F));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 55F));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

            var fields = new ListView
            {
                Dock = DockStyle.Fill,
                View = View.Details,
                FullRowSelect = true,
                HeaderStyle = ColumnHeaderStyle.Nonclickable,
                MultiSelect = false,
                GridLines = true,
            };
            fields.Columns.Add("Field", 160);
            fields.Columns.Add("Value", 420);
            if (report != null)
            {
                foreach (KeyValuePair<string, string> row in report.Summary())
                {
                    fields.Items.Add(new ListViewItem(new[] { row.Key, row.Value }));
                }
            }
            else
            {
                fields.Items.Add(new ListViewItem(new[] { "Report", error ?? "No report is available." }));
            }

            var raw = new TextBox
            {
                Dock = DockStyle.Fill,
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Both,
                WordWrap = false,
                Font = new Font(FontFamily.GenericMonospace, 9F),
                Text = report != null ? report.RawJson : string.Empty,
            };

            var close = new Button { Text = "Close", AutoSize = true, Anchor = AnchorStyles.Right };
            // The window is shown modeless from the tray, so DialogResult alone would not close it.
            close.Click += (sender, args) => Close();
            CancelButton = close;
            AcceptButton = close;

            layout.Controls.Add(fields, 0, 0);
            layout.Controls.Add(raw, 0, 1);
            layout.Controls.Add(close, 0, 2);
            Controls.Add(layout);
        }
    }
}
