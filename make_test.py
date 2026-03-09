import struct

# あなたのISAと完全に一致する「ABC」を送信して無限ループする機械語
instructions = [
    0x3c0fffff, # lui $t7, 65535      (UARTアドレス 0xFFFF0000)
    0x20020041, # addi $v0, $zero, 65 ('A')
    0xade20000, # sw $v0, 0($t7)
    0x20020042, # addi $v0, $zero, 66 ('B')
    0xade20000, # sw $v0, 0($t7)
    0x20020043, # addi $v0, $zero, 67 ('C')
    0xade20000, # sw $v0, 0($t7)
    0x08010001  # j 0x040004          (loop)
]

with open("test.bin", "wb") as f:
    for inst in instructions:
        f.write(struct.pack('<I', inst))

print("test.bin を生成しました！")