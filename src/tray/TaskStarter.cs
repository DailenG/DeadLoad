using System;
using System.Reflection;
using System.Runtime.InteropServices;

namespace DeadLoad.Tray
{
    /// <summary>
    /// Starts the SYSTEM task \DeadLoad\OnDemand. The task's security descriptor lets
    /// Authenticated Users run it, so no elevation is needed; the cleanup itself runs as SYSTEM
    /// under the engine's own safety rules, never in the user's process.
    /// </summary>
    internal static class TaskStarter
    {
        public const string FolderPath = @"\DeadLoad";
        public const string TaskName = "OnDemand";

        /// <summary>Starts the task; returns null on success, else a message for the user.</summary>
        public static string StartOnDemand()
        {
            // Late binding through the ProgID keeps the exe free of an interop assembly.
            Type type = Type.GetTypeFromProgID("Schedule.Service", false);
            if (type == null) { return "The Task Scheduler service is not available."; }

            object service = null;
            object folder = null;
            object task = null;
            object running = null;
            try
            {
                service = Activator.CreateInstance(type);
                Call(service, "Connect");
                folder = Call(service, "GetFolder", FolderPath);
                task = Call(folder, "GetTask", TaskName);
                // Run(params): null means no parameters. It starts the task as registered
                // (SYSTEM); the caller only needs the execute right the descriptor grants.
                running = Call(task, "Run", new object[] { null });
                return null;
            }
            catch (TargetInvocationException ex)
            {
                return Describe(ex.InnerException ?? ex);
            }
            catch (Exception ex)
            {
                return Describe(ex);
            }
            finally
            {
                Release(running);
                Release(task);
                Release(folder);
                Release(service);
            }
        }

        private static string Describe(Exception ex)
        {
            var com = ex as COMException;
            int code = com != null ? com.ErrorCode : ex.HResult;
            // 0x80070002 file not found: the task (or folder) is not registered.
            if (code == unchecked((int)0x80070002) || code == unchecked((int)0x80070003))
            {
                return "The cleanup task is not installed on this computer.";
            }
            // 0x80070005 access denied: the descriptor does not let this user run it.
            if (code == unchecked((int)0x80070005))
            {
                return "You are not allowed to start the cleanup task.";
            }
            return "The cleanup could not be started: " + ex.Message;
        }

        private static object Call(object target, string method, params object[] args)
        {
            return target.GetType().InvokeMember(method, BindingFlags.InvokeMethod, null, target, args);
        }

        private static void Release(object com)
        {
            if (com != null && Marshal.IsComObject(com))
            {
                Marshal.ReleaseComObject(com);
            }
        }
    }
}
