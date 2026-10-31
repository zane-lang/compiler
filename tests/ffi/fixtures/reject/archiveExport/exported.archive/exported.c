/* Exported from a DLL the member would be linked into, which writes a
   `/EXPORT:exported` directive into the object's `.drectve` section. */
__declspec(dllexport) long long exported(void) { return 1; }
