using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Dayflow.Core.Security
{
    /// <summary>
    /// Manages secure credential storage using Windows Credential Manager
    /// Equivalent to macOS Keychain
    /// </summary>
    public class CredentialManager
    {
        private const string TARGET_PREFIX = "Dayflow.ApiKeys.";

        /// <summary>
        /// Stores an API key securely in Windows Credential Manager
        /// </summary>
        public bool SaveApiKey(string provider, string apiKey)
        {
            try
            {
                var target = TARGET_PREFIX + provider;
                var credential = new CREDENTIAL
                {
                    Type = CRED_TYPE.GENERIC,
                    TargetName = target,
                    UserName = "Dayflow",
                    CredentialBlob = Marshal.StringToCoTaskMemUni(apiKey),
                    CredentialBlobSize = (uint)(Encoding.Unicode.GetByteCount(apiKey) * 2),
                    Persist = CRED_PERSIST.LOCAL_MACHINE,
                    AttributeCount = 0,
                    Attributes = IntPtr.Zero,
                    TargetAlias = null,
                    Comment = $"Dayflow API key for {provider}"
                };

                bool result = CredWrite(ref credential, 0);
                Marshal.FreeCoTaskMem(credential.CredentialBlob);

                return result;
            }
            catch (Exception ex)
            {
                Sentry.SentrySdk.CaptureException(ex);
                return false;
            }
        }

        /// <summary>
        /// Retrieves an API key from Windows Credential Manager
        /// </summary>
        public string? GetApiKey(string provider)
        {
            try
            {
                var target = TARGET_PREFIX + provider;
                if (CredRead(target, CRED_TYPE.GENERIC, 0, out IntPtr credPtr))
                {
                    var credential = Marshal.PtrToStructure<CREDENTIAL>(credPtr);
                    string? password = null;

                    if (credential.CredentialBlobSize > 0)
                    {
                        password = Marshal.PtrToStringUni(
                            credential.CredentialBlob,
                            (int)credential.CredentialBlobSize / 2);
                    }

                    CredFree(credPtr);
                    return password;
                }

                return null;
            }
            catch (Exception ex)
            {
                Sentry.SentrySdk.CaptureException(ex);
                return null;
            }
        }

        /// <summary>
        /// Deletes an API key from Windows Credential Manager
        /// </summary>
        public bool DeleteApiKey(string provider)
        {
            try
            {
                var target = TARGET_PREFIX + provider;
                return CredDelete(target, CRED_TYPE.GENERIC, 0);
            }
            catch (Exception ex)
            {
                Sentry.SentrySdk.CaptureException(ex);
                return false;
            }
        }

        #region Windows API Imports

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite([In] ref CREDENTIAL credential, [In] uint flags);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(
            string target,
            CRED_TYPE type,
            int reservedFlag,
            out IntPtr credentialPtr);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDelete(string target, CRED_TYPE type, int flags);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool CredFree([In] IntPtr cred);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public uint Flags;
            public CRED_TYPE Type;
            public string TargetName;
            public string? Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;
            public CRED_PERSIST Persist;
            public uint AttributeCount;
            public IntPtr Attributes;
            public string? TargetAlias;
            public string? UserName;
        }

        private enum CRED_TYPE
        {
            GENERIC = 1,
            DOMAIN_PASSWORD = 2,
            DOMAIN_CERTIFICATE = 3,
            DOMAIN_VISIBLE_PASSWORD = 4
        }

        private enum CRED_PERSIST
        {
            SESSION = 1,
            LOCAL_MACHINE = 2,
            ENTERPRISE = 3
        }

        #endregion
    }
}
