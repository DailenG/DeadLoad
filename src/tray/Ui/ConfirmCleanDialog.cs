using System;
using System.Drawing;
using System.Windows.Forms;

namespace DeadLoad.Tray.Ui
{
    /// <summary>
    /// The confirmation before a cleanup (design system section 9). Cancel has the focus and is
    /// the Escape key; Enter on Cancel cancels. Only "Clean Selected Items" returns OK.
    /// </summary>
    internal sealed class ConfirmCleanDialog : Form
    {
        public const string Heading = "Clean selected items?";

        public ConfirmCleanDialog(int files, int categories, long estimatedBytes)
        {
            Palette p = ThemeManager.Palette;
            Text = Heading;
            AutoScaleMode = AutoScaleMode.None;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = false;
            ShowIcon = false;
            StartPosition = FormStartPosition.CenterParent;
            KeyPreview = true;
            BackColor = p.Card;

            Body = BodyText(files, categories, estimatedBytes);
            var root = new StackPanel
            {
                Padding = new Padding(ThemeManager.S(24), ThemeManager.S(20), ThemeManager.S(24), ThemeManager.S(20)),
                Spacing = ThemeManager.S(12),
                BackColor = p.Card,
            };
            var title = new TextBlock(Heading, ThemeManager.Semibold(FontRole.Display, ThemeTokens.FontSizeAppTitlePx), p.Heading, true);
            root.Controls.Add(title);
            root.Controls.Add(new TextBlock(Body, ThemeManager.Font(FontRole.Text, ThemeTokens.FontSizeAppBodyPx), p.TextPrimary, true));
            var bar = new ButtonBar(true) { Margin = new Padding(0, ThemeManager.S(8), 0, 0) };
            CleanButton = bar.Add(new ThemedButton("Clean Selected Items", ButtonKind.Primary, true));
            CancelButtonControl = bar.Add(new ThemedButton("Cancel", ButtonKind.Secondary, true));
            CancelButtonControl.TabIndex = 0;
            CleanButton.TabIndex = 1;
            CleanButton.DialogResult = DialogResult.OK;
            CancelButtonControl.DialogResult = DialogResult.Cancel;
            root.Controls.Add(bar);
            Surfaces.Apply(root);

            int width = ThemeManager.S(480);
            int height = root.GetPreferredSize(new Size(width, 0)).Height;
            ClientSize = new Size(width, height);
            root.Dock = DockStyle.Fill;
            Controls.Add(root);

            CancelButton = CancelButtonControl;
            // No AcceptButton: Enter must never clean unless the Clean button itself has the focus.
            ActiveControl = CancelButtonControl;
            AccessibleName = Heading;
            AccessibleDescription = Body;
        }

        public string Body { get; private set; }

        public ThemedButton CleanButton { get; private set; }

        public ThemedButton CancelButtonControl { get; private set; }

        public static string BodyText(int files, int categories, long estimatedBytes)
        {
            return "You're about to remove " + Format.Count(files, "selected file", "selected files") +
                " across " + Format.Count(categories, "category", "categories") +
                " (estimated " + Format.Bytes(estimatedBytes) + "). Review the included paths before continuing. Deleted files cannot be restored by DeadLoad.";
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            NativeMethods.SetDarkTitleBar(Handle, ThemeManager.Palette.IsDark);
            NativeMethods.ShowFocusCues(this);
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            CancelButtonControl.Focus();
        }
    }
}
