import struct
import os

# 入力ファイルと出力ファイルの名前
input_file = 'output.hex'
output_file = 'output.bin'

def convert_base2_to_bin():
    if not os.path.exists(input_file):
        print(f"エラー: {input_file} が見つかりません。")
        return

    with open(input_file, 'r') as f_in, open(output_file, 'wb') as f_out:
        for line in f_in:
            line = line.strip()
            # 空行やコメントをスキップ
            if not line or line.startswith('#') or line.startswith('//'):
                continue
            
            # ★修正: 16進数ではなく、2進数(Base-2)文字列として32ビット整数に変換
            val = int(line, 2)
            
            # リトルエンディアンの4バイト（32ビット）バイナリとして書き込み
            f_out.write(struct.pack('<I', val))
            
    print(f"成功: '{input_file}' を本物のバイナリ '{output_file}' に変換しました！")

if __name__ == '__main__':
    convert_base2_to_bin()