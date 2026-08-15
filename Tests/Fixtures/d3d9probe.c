/*
 * Minimal i386 D3D9 probe: creates a windowed HAL device, clears, presents a
 * few frames, prints the adapter identity and a couple of caps, then exits.
 * Used to smoke-test which d3d9 implementation actually loaded (mtld3d vs
 * wine's builtin) under the bundled runtime, and to exercise x87 code so the
 * x87sidecar attach path runs.
 */
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <math.h>

int main(void)
{
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) { printf("PROBE: Direct3DCreate9 FAILED\n"); fflush(stdout); return 2; }
    printf("PROBE: Direct3DCreate9 ok\n"); fflush(stdout);

    D3DADAPTER_IDENTIFIER9 id;
    memset(&id, 0, sizeof(id));
    if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &id))) {
        printf("PROBE: driver=%s\nPROBE: description=%s\nPROBE: vendor=0x%04x device=0x%04x\n",
               id.Driver, id.Description, id.VendorId, id.DeviceId);
    } else {
        printf("PROBE: GetAdapterIdentifier FAILED\n");
    }
    fflush(stdout);

    D3DCAPS9 caps;
    if (SUCCEEDED(IDirect3D9_GetDeviceCaps(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, &caps))) {
        printf("PROBE: vs=%u.%u ps=%u.%u maxtex=%lu simultaneousRT=%lu\n",
               (unsigned)((caps.VertexShaderVersion >> 8) & 0xff), (unsigned)(caps.VertexShaderVersion & 0xff),
               (unsigned)((caps.PixelShaderVersion >> 8) & 0xff), (unsigned)(caps.PixelShaderVersion & 0xff),
               (unsigned long)caps.MaxTextureWidth, (unsigned long)caps.NumSimultaneousRTs);
    } else {
        printf("PROBE: GetDeviceCaps FAILED\n");
    }
    fflush(stdout);

    WNDCLASSA wc; memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "d3d9probe";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("d3d9probe", "d3d9probe", WS_OVERLAPPEDWINDOW,
                              0, 0, 640, 480, NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) { printf("PROBE: CreateWindow FAILED\n"); fflush(stdout); return 3; }

    D3DPRESENT_PARAMETERS pp; memset(&pp, 0, sizeof(pp));
    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = D3DFMT_UNKNOWN;
    pp.hDeviceWindow = hwnd;

    IDirect3DDevice9 *dev = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                         D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &dev);
    if (FAILED(hr) || !dev) {
        printf("PROBE: CreateDevice FAILED hr=0x%08lx\n", (unsigned long)hr);
        fflush(stdout);
        return 4;
    }
    printf("PROBE: CreateDevice ok\n"); fflush(stdout);

    /* x87-heavy loop: gives the sidecar's JIT real transcendental work. */
    volatile double acc = 0.0;
    for (int i = 1; i < 200000; i++) acc += sin((double)i) * cos((double)i) / sqrt((double)i);
    printf("PROBE: x87 loop result=%.6f\n", (double)acc); fflush(stdout);

    for (int frame = 0; frame < 3; frame++) {
        IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(20, 40, 80), 1.0f, 0);
        IDirect3DDevice9_BeginScene(dev);
        IDirect3DDevice9_EndScene(dev);
        HRESULT ph = IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL);
        printf("PROBE: frame %d present hr=0x%08lx\n", frame, (unsigned long)ph);
        fflush(stdout);
    }

    IDirect3DDevice9_Release(dev);
    IDirect3D9_Release(d3d);
    printf("PROBE: DONE ok\n"); fflush(stdout);
    return 0;
}
