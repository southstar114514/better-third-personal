#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

/* PluginId001 / PluginCallbacks001, matching Northstar's public x64 ABI.
   Explicit vtables avoid any compiler-specific C++ runtime dependency. */
static const BYTE camera_before[] = {0x48,0x8b,0x05,0x86,0x0a,0xae,0x00};
static const BYTE camera_after[] = {0xe9,0x4b,0,0,0,0x90,0x90};
static const BYTE gate_before[] = {0x0f,0x84,0x62,0x06,0,0};
static const BYTE gate_after[] = {0xe9,0x32,0x3e,0x73,0,0x90};
static const BYTE shim[] = {
    0x0f,0x85,0xc9,0xc1,0x8c,0xff,0x48,0x8b,0xcb,0xe8,0x3a,0x79,
    0xb4,0xff,0x84,0xc0,0x0f,0x85,0xb9,0xc1,0x8c,0xff,0x48,0x8b,
    0xcb,0xe8,0x82,0xeb,0x81,0xff,0x48,0x85,0xc0,0x0f,0x84,0x0a,
    0xc8,0x8c,0xff,0x48,0x8b,0xc8,0xe8,0xf1,0x6a,0xd1,0xff,0x48,
    0x8d,0x15,0x24,0,0,0,0xb9,0x13,0,0,0,0x44,
    0x8a,0,0x44,0x3a,0x02,0x0f,0x85,0xea,0xc7,0x8c,0xff,0x48,
    0xff,0xc0,0x48,0xff,0xc2,0xff,0xc9,0x0f,0x85,0xe6,0xff,0xff,
    0xff,0xe9,0x75,0xc1,0x8c,0xff,0x6d,0x70,0x5f,0x77,0x65,0x61,
    0x70,0x6f,0x6e,0x5f,0x64,0x65,0x66,0x65,0x6e,0x64,0x65,0x72,0
};
static const BYTE zero_shim[sizeof(shim)] = {0};
static const BYTE supported_hash[32] = {
    0x00,0x2b,0x36,0x48,0x7f,0xec,0x7c,0x98,0x88,0x29,0x29,0xfb,0xcc,0xdb,0x50,0x6d,
    0x01,0x46,0xbb,0xf3,0x27,0x0c,0xbb,0x96,0x4a,0x4d,0x21,0xc5,0xed,0xf7,0xee,0xbc
};
static volatile LONG attempted;
static bool applied;

static void Log(const char *message)
{
    HMODULE self;
    WCHAR path[32768];
    char line[512];
    DWORD written;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCWSTR)&Log, &self)) return;
    DWORD length = GetModuleFileNameW(self, path, 32768);
    if (!length || length >= 32740) return;
    while (length && path[length-1] != L'\\') --length;
    lstrcpyW(path + length, L"TPA.Native.log");
    int size = wsprintfA(line, "PID=%lu %s\r\n", GetCurrentProcessId(), message);
    OutputDebugStringA(line);
    HANDLE file = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS, 0, NULL);
    if (file != INVALID_HANDLE_VALUE) {
        WriteFile(file, line, size, &written, NULL);
        CloseHandle(file);
    }
}

static bool Supported(HMODULE client)
{
    WCHAR path[32768];
    BYTE buffer[32768], hash[32];
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hasher = NULL;
    DWORD count;
    bool ok = false;
    DWORD length = GetModuleFileNameW(client, path, 32768);
    if (!length || length >= 32768) return false;
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (file == INVALID_HANDLE_VALUE) return false;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0) < 0) goto done;
    if (BCryptCreateHash(algorithm, &hasher, NULL, 0, NULL, 0, 0) < 0) goto done;
    for (;;) {
        if (!ReadFile(file, buffer, sizeof(buffer), &count, NULL)) goto done;
        if (!count) break;
        if (BCryptHashData(hasher, buffer, count, 0) < 0) goto done;
    }
    if (BCryptFinishHash(hasher, hash, sizeof(hash), 0) < 0) goto done;
    ok = memcmp(hash, supported_hash, sizeof(hash)) == 0;
done:
    if (hasher) BCryptDestroyHash(hasher);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    CloseHandle(file);
    return ok;
}

static bool Write(BYTE *address, const BYTE *bytes, SIZE_T size)
{
    DWORD old, ignored;
    if (!memcmp(address, bytes, size)) return true;
    if (!VirtualProtect(address, size, PAGE_EXECUTE_READWRITE, &old)) return false;
    memcpy(address, bytes, size);
    bool flushed = FlushInstructionCache(GetCurrentProcess(), address, size) != 0;
    bool restored = VirtualProtect(address, size, old, &ignored) != 0;
    return flushed && restored && !memcmp(address, bytes, size);
}

static void Apply(HMODULE module)
{
    if (!module || InterlockedCompareExchange(&attempted, 1, 0)) return;
    if (!Supported(module)) { Log("ERROR unsupported client.dll SHA256; no memory changed"); return; }
    BYTE *base = (BYTE *)module;
    const DWORD offsets[] = {0x14fd03, 0x892e20, 0x15efe9};
    const BYTE *before[] = {camera_before, zero_shim, gate_before};
    const BYTE *after[] = {camera_after, shim, gate_after};
    const SIZE_T sizes[] = {sizeof(camera_before), sizeof(shim), sizeof(gate_before)};
    BYTE saved[3][sizeof(shim)];
    for (int i = 0; i < 3; ++i) {
        memcpy(saved[i], base + offsets[i], sizes[i]);
        if (memcmp(saved[i], before[i], sizes[i]) && memcmp(saved[i], after[i], sizes[i])) {
            Log("ERROR unexpected instructions; no memory changed"); return;
        }
    }
    /* Load callback runs before client code starts: install shim before redirect. */
    for (int i = 0; i < 3; ++i) {
        if (!Write(base + offsets[i], after[i], sizes[i])) {
            bool restored = true;
            for (int j = i; j >= 0; --j)
                if (!Write(base + offsets[j], saved[j], sizes[j])) restored = false;
            Log(restored ? "ERROR patch write failed; prior bytes restored" : "ERROR patch and restore failed; restart game");
            return;
        }
    }
    applied = true;
    Log("READY camera + native Titan/Charge Rifle reticles; 122 bytes verified");
}

static const char *GetString(void *self, int field)
{
    (void)self;
    switch (field) {
    case 0: return "ThirdPersonAim Native";
    case 1: return "TPA.Native";
    case 2: return "TPA_NATIVE";
    default: return NULL;
    }
}
static int64_t GetField(void *self, int field) { (void)self; return field == 0 ? 2 : 0; }
static void Init(void *self, HMODULE northstar, const void *data, bool reloaded)
{
    (void)self; (void)northstar; (void)data; (void)reloaded;
    Log("INIT PluginCallbacks001 client-only");
    Apply(GetModuleHandleW(L"client.dll"));
}
static void NoOp(void *self) { (void)self; }
static bool Unload(void *self) { (void)self; return !applied; }
static void VmNoOp(void *self, void *vm) { (void)self; (void)vm; }
static void OnLibraryLoaded(void *self, HMODULE module, const char *name)
{
    (void)self;
    if (!lstrcmpiA(name, "client.dll")) Apply(module);
}
static const void *const id_methods[] = {(void *)GetString, (void *)GetField};
static const void *const callback_methods[] = {
    (void *)Init, (void *)NoOp, (void *)Unload, (void *)VmNoOp, (void *)VmNoOp, (void *)OnLibraryLoaded, (void *)NoOp
};
static struct { const void *const *vtable; } id = {id_methods}, callbacks = {callback_methods};
__declspec(dllexport) void *CreateInterface(const char *name, int *status)
{
    void *result = NULL;
    if (!lstrcmpA(name, "PluginId001")) result = &id;
    else if (!lstrcmpA(name, "PluginCallbacks001")) result = &callbacks;
    if (status) *status = result ? 0 : 1;
    return result;
}
