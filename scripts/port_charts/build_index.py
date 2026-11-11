# 生成した港の海図（out/<id>.jpg と out/<id>.json）を、アプリの同梱データにまとめる。
# 使い方: python3 scripts/port_charts/build_index.py <out フォルダ>
#   → App/Resources/Charts/<id>.jpg と Packages/Core/Sources/Core/Data/port_charts.json
import json, glob, os, shutil, sys
src = sys.argv[1]
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
charts_dir = os.path.join(root, 'App', 'Resources', 'Charts')
os.makedirs(charts_dir, exist_ok=True)
index = []
for f in sorted(glob.glob(os.path.join(src, '*.json'))):
    d = json.load(open(f))
    jpg = f[:-5] + '.jpg'
    if not d.get('ok') or not os.path.exists(jpg): continue
    shutil.copyfile(jpg, os.path.join(charts_dir, d['id'] + '.jpg'))
    index.append({k: d[k] for k in ('id', 'name', 'lat', 'lon', 'widthM', 'heightM', 'cols', 'rows', 'water')})
index.sort(key=lambda d: d['id'])
# 索引に無い絵（枠を置き直して id が変わった港の古い絵）は消す
keep = {d['id'] + '.jpg' for d in index}
for old in glob.glob(os.path.join(charts_dir, '*.jpg')):
    if os.path.basename(old) not in keep: os.remove(old)
out = os.path.join(root, 'Packages', 'Core', 'Sources', 'Core', 'Data', 'port_charts.json')
json.dump(index, open(out, 'w'), ensure_ascii=False, separators=(',', ':'))
print(len(index), 'charts ->', out)
