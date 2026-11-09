"""FishBase の和名ローマ字（ヘボン式、長音なし、例 "Hime-uba-uo"）をカタカナに直す。推定なので表示では「推定」と添える。"""
import re
_TABLE = {
 "kya":"キャ","kyu":"キュ","kyo":"キョ","sha":"シャ","shu":"シュ","sho":"ショ","cha":"チャ","chu":"チュ","cho":"チョ","nya":"ニャ","nyu":"ニュ","nyo":"ニョ",
 "hya":"ヒャ","hyu":"ヒュ","hyo":"ヒョ","mya":"ミャ","myu":"ミュ","myo":"ミョ","rya":"リャ","ryu":"リュ","ryo":"リョ","gya":"ギャ","gyu":"ギュ","gyo":"ギョ",
 "ja":"ジャ","ju":"ジュ","jo":"ジョ","jya":"ジャ","jyu":"ジュ","jyo":"ジョ","bya":"ビャ","byu":"ビュ","byo":"ビョ","pya":"ピャ","pyu":"ピュ","pyo":"ピョ",
 "shi":"シ","chi":"チ","tsu":"ツ","tu":"ツ","fu":"フ","hu":"フ","ji":"ジ","zi":"ジ","di":"ヂ","du":"ヅ","dzu":"ヅ","she":"シェ","che":"チェ","je":"ジェ","tsa":"ツァ","tse":"ツェ","tso":"ツォ","fa":"ファ","fi":"フィ","fe":"フェ","fo":"フォ","ti":"ティ","wi":"ウィ","we":"ウェ","wo":"ヲ","vu":"ヴ",
 "ka":"カ","ki":"キ","ku":"ク","ke":"ケ","ko":"コ","sa":"サ","si":"シ","su":"ス","se":"セ","so":"ソ","ta":"タ","te":"テ","to":"ト","na":"ナ","ni":"ニ","nu":"ヌ","ne":"ネ","no":"ノ",
 "ha":"ハ","hi":"ヒ","he":"ヘ","ho":"ホ","ma":"マ","mi":"ミ","mu":"ム","me":"メ","mo":"モ","ya":"ヤ","yu":"ユ","yo":"ヨ","ra":"ラ","ri":"リ","ru":"ル","re":"レ","ro":"ロ","wa":"ワ",
 "ga":"ガ","gi":"ギ","gu":"グ","ge":"ゲ","go":"ゴ","za":"ザ","zu":"ズ","ze":"ゼ","zo":"ゾ","da":"ダ","de":"デ","do":"ド","ba":"バ","bi":"ビ","bu":"ブ","be":"ベ","bo":"ボ","pa":"パ","pi":"ピ","pu":"プ","pe":"ペ","po":"ポ",
 "a":"ア","i":"イ","u":"ウ","e":"エ","o":"オ","n":"ン",
}
_KEYS = sorted(_TABLE, key=len, reverse=True)

def romaji_to_katakana(s):
    s = s.strip().lower()
    if not s or not re.fullmatch(r"[a-z\-' ]+", s): return None
    out = []
    for word in re.split(r"[-' ]+", s):
        i = 0; buf = ""
        while i < len(word):
            # 促音：同じ子音が続く（kk, tt, ss, pp …。n は撥音）
            if i + 1 < len(word) and word[i] == word[i + 1] and word[i] not in "aeiou" and word[i] != "n":
                buf += "ッ"; i += 1; continue
            if word.startswith("tch", i): buf += "ッ"; i += 1; continue
            # 撥音：n の後ろが母音・y でない
            if word[i] == "n" and (i + 1 == len(word) or word[i + 1] not in "aeiouy"):
                buf += "ン"; i += 1; continue
            matched = False
            for k in _KEYS:
                if word.startswith(k, i):
                    buf += _TABLE[k]; i += len(k); matched = True; break
            if not matched:
                return None  # 読めない綴り（アルファベットのまま使わない）
        out.append(buf)
    return "".join(out)

if __name__ == "__main__":
    import sys
    for t in sys.argv[1:] or ["Kanranhagi", "Hime-uba-uo", "Nise-kanranhagi", "Gomanizama", "Shima-hagi", "Hotchare", "Kinchakudai", "Aka-matsukasa", "Sappa", "Mebaru"]:
        print(t, "→", romaji_to_katakana(t))
