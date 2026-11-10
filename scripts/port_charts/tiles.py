# 国土地理院タイルから、港のまわりの航空写真と淡色地図を 3:4 で切り出す
import math, sys, io, json, subprocess
from PIL import Image
def deg2num(lat, lon, z):
    n=2**z; x=(lon+180)/360*n; y=(1-math.asinh(math.tan(math.radians(lat)))/math.pi)/2*n; return x,y
def fetch(layer, ext, z, x, y):
    url=f"https://cyberjapandata.gsi.go.jp/xyz/{layer}/{z}/{x}/{y}.{ext}"
    r=subprocess.run(["curl","-sS","-m","30","-A","fog-theme-builder","-o","-","-w","%{http_code}",url],capture_output=True)
    code=r.stdout[-3:].decode(errors='ignore'); data=r.stdout[:-3]
    if code!="200": return None
    try: return Image.open(io.BytesIO(data)).convert('RGB')
    except Exception: return None
def area(lat, lon, z=17, w_m=820, h_m=1093):
    mpp=156543.03392*math.cos(math.radians(lat))/2**z
    wpx,hpx=int(w_m/mpp),int(h_m/mpp)
    cx,cy=deg2num(lat,lon,z); px,py=cx*256,cy*256
    x0,y0=px-wpx/2,py-hpx/2
    tx0,ty0,tx1,ty1=int(x0//256),int(y0//256),int((x0+wpx)//256),int((y0+hpx)//256)
    out={}
    for layer,ext in (("seamlessphoto","jpg"),("pale","png")):
        canvas=Image.new('RGB',((tx1-tx0+1)*256,(ty1-ty0+1)*256),(128,128,128)); miss=0
        for tx in range(tx0,tx1+1):
            for ty in range(ty0,ty1+1):
                im=fetch(layer,ext,z,tx,ty)
                if im is None: miss+=1; continue
                canvas.paste(im,((tx-tx0)*256,(ty-ty0)*256))
        ox,oy=int(x0-tx0*256),int(y0-ty0*256)
        out[layer]=(canvas.crop((ox,oy,ox+wpx,oy+hpx)),miss)
    return out,mpp
if __name__=="__main__":
    name,lat,lon=sys.argv[1],float(sys.argv[2]),float(sys.argv[3])
    w=float(sys.argv[4]) if len(sys.argv)>4 else 820
    out,mpp=area(lat,lon,17,w,w*4/3)
    for k,(im,miss) in out.items():
        im=im.resize((1200,1600),Image.LANCZOS); im.save(f"{name}_{k}.jpg",quality=90); print(name,k,im.size,'missing tiles',miss,'m/px',round(mpp*out[k][0].width/1200,2))
