# ผลการสร้าง Dataset และ Train: Dynamic Weight Shifts

> เอกสารนี้เป็นผลย้อนหลังของ prototype แบบ weak-rule 3 phase / 2 class เท่านั้น
> ไม่ใช่สัญญา Dataset ปัจจุบัน ปัจจุบันใช้ `rest/target`, 4 class และ landmark
> 16 features จากหัวไหล่และสะโพก โดยไม่มี `trunk_shift` ใน JSON หรือ model
> input ดู `README.md`
> สำหรับ flow ที่ใช้งานจริง

## ผลล่าสุด: Synthetic per-rep v3

ชุดหลักมี 313 rows: rep จริง 33 และ synthetic train-only 280 รายการ แต่ละ rep ฝั่ง train 7 ตัวถูกสร้างเพิ่มตัวละ 40 variants จาก amplitude 8 ระดับ × speed 5 ระดับ พร้อม mirror, camera scale/translation และ smooth landmark jitter แบบทำซ้ำผลได้

validation/test ในชุดหลักเป็น rep จริงเท่านั้น ส่วน synthetic boundary 104 รายการถูกเก็บในไฟล์ diagnostic แยก ไม่รวมเป็น primary clinical metric

ผล audit ของ v3:

| การตรวจ | ผล |
|---|---:|
| Label ข้ามเส้น 2.5° | 0 |
| Lineage ข้าม split | 0 |
| Random augmentation นอก train | 0 |
| Synthetic ใน main validation/test | 0 |
| Feature shape | 3,762 windows × 30 × 42 |

## Accuracy experiments

พบ root cause ของ v2 ว่า synthetic ที่ย่อ amplitude ยังคัดลอก target phase เดิม ทำให้ reached-positive windows บางส่วนมีมุมจริงต่ำกว่า 2.5° รวม 336 windows ใน feature set รอบเดิม นอกจากนี้ quality head เดิมใช้มุม frame ล่าสุดที่หารด้วย 180 จึงมีสเกลเล็กและลืม peak ที่เกิดก่อนหน้า

ทดลอง architecture/feature 6 แบบ โดยใช้ `IMG_2944` เลือกโมเดลและเปิด `IMG_2945` test หลังเลือกเสร็จ:

| Iteration | Feature/head | Validation accuracy |
|---|---|---:|
| E01 | last angle แบบเดิม | 80.82% |
| E02 | causal maximum | 90.59% |
| **E03** | **clean causal-max + scale เป็นองศา** | **100.00%** |
| E04 | max/last/mean statistics | 95.25% |
| E05 | larger quality head | 100.00% |
| E06 | monotonic head | 100.00% |

E03 ถูกเลือกจาก validation ด้วย threshold 0.40 ผล test แยกตามชนิดข้อมูลคือ real-only reached recall 100% จาก 82 windows และ synthetic-boundary accuracy/Macro-F1 100%, false-good 0%

ทดลอง pipeline กับ dataset augmented v3 เพิ่มอีก 2 configuration พบว่า quality-focused ชนะ multitask บน validation และได้ผล test ดังนี้:

| Test set | Quality result |
|---|---:|
| Real-only | reached recall 100% จาก 83 windows; ไม่มี real negative |
| Boundary diagnostic | accuracy 100%, Macro-F1 100%, false-good 0% |
| Phase บน real-only | 17.9% |
| Phase บน diagnostic | 25.9% |

ดังนั้น AI quality head สามารถเลียนแบบ weak rule 2.5° ได้ครบในชุดนี้ แต่ phase head ยังไม่พร้อมใช้งาน ระบบยังใช้ rulebase สำหรับ phase และการนับ rep โมเดลที่ export เป็น TFJS ยังคง `validationOnly: true` และไม่ถูก publish

ตัวเลข 100% ไม่ใช่ clinical accuracy เพราะข้อมูลจริงมาจากผู้เข้าร่วมคนเดียว และไม่มี rep จริงฝั่ง `not_reached_target`

## ชุดข้อมูล

ตัดข้อมูลออกเป็น 33 rep จริงจาก 3 วิดีโอ โดยแต่ละ rep เก็บเวลาเริ่ม–จบ เฟรม landmark และ tag กำกับไว้ใน `dataset.jsonl`

| รายการ | จำนวน |
|---|---:|
| rep จริง | 33 |
| ตัวอย่างจำลองใกล้ threshold | 195 |
| รวม | 228 |
| ทิศซ้าย / ขวา | 17 / 16 rep จริง |
| ถึงเป้า / ไม่ถึงเป้า | 129 / 99 |

ตัวอย่างจำลองฝั่งไม่ถึงเป้าอยู่ที่ 1.8°, 2.2° และ 2.4° ส่วนฝั่งถึงเป้าอยู่ที่ 2.6°, 3.2° และ 4.0° เกณฑ์ต้นแบบคือ 2.5° ทุกข้อมูลจำลองเชื่อมกลับไปยัง rep ต้นทางด้วย `splitLineageId`

ข้อมูลถูกแยกตามวิดีโอ: `IMG_2943` เป็น train, `IMG_2944` เป็น validation และ `IMG_2945` เป็น test จึงไม่มีหน้าต่างจากวิดีโอเดียวกันรั่วข้ามชุด

## Tags ที่บันทึก

- ทิศทางกายวิภาคและทิศบนหน้าจอ
- ระดับ amplitude และความเร็ว
- แหล่ง label แบบ weak rule
- ลำดับ center–target–center
- MediaPipe Pose Heavy
- กล้องด้านหน้าและสถานะ mirror
- ตัวอย่างจริงหรือตัวอย่างจำลอง พร้อมค่าองศาของ boundary

ทุก label ยังมีสถานะ `draft`, `trainable=false`, `scoreable=false` และ `clinicalReviewRequired=true` การฝึกครั้งนี้จึงเป็น prototype เท่านั้น

## Rulebase

กฎนับ rep ใช้ `trunk_shift` ซึ่งคำนวณจากแนวกึ่งกลางหัวไหล่เทียบกับกึ่งกลางสะโพก:

1. ผ่านกึ่งกลางที่ไม่เกิน 1.0° เพื่อเตรียมนับ
2. เคลื่อนไปถึงอย่างน้อย 2.5° และค้าง 150 ms
3. ต้องกลับผ่านกึ่งกลางไม่เกิน 1.0° จึงถือว่า excursion สมบูรณ์

ท่านี้เป็นการเคลื่อนไหวซ้าย–ขวาต่อเนื่อง จึงใช้การผ่านกึ่งกลางเพื่อเตรียม rep ถัดไป โดยไม่บังคับให้หยุดค้างตรงกลาง

ผลตรวจความสอดคล้องของ rulebase กับ dataset 228 รายการ:

| ตัวชี้วัด | ผล |
|---|---:|
| Rep accuracy | 100% |
| Recall: ถึงเป้า | 100% |
| Recall: ไม่ถึงเป้า | 100% |
| False reached | 0% |

ผลนี้เป็นการตรวจว่า segmentation, labels และ runtime rule ใช้เงื่อนไขเดียวกันได้ถูกต้อง ไม่ใช่ผลทดสอบกับผู้ป่วยรายใหม่

## โมเดล TCN รอบสอง

โมเดลรับข้อมูลลำดับ 30 เฟรม × 42 ฟีเจอร์ จำนวน 2,447 windows และประเมินกับวิดีโอ test ที่ไม่อยู่ใน train

| ตัวชี้วัดบน test | รอบแรก | รอบสอง |
|---|---:|---:|
| Quality accuracy | 73.2% | 78.9% |
| Quality macro-F1 | 71.1% | 78.9% |
| Recall: ถึงเป้า | 46.3% | 68.3% |
| Recall: ไม่ถึงเป้า | 100.0% | 92.7% |
| False-good rate | 0.0% | 7.3% |
| Phase accuracy | 20.1% | 20.1% |

รอบสองดีขึ้นด้านการจำแนกถึงเป้า/ไม่ถึงเป้า แต่ยังไม่ผ่านเกณฑ์อนุมัติของระบบ โมเดล phase ทำนายเป็น `rest` เกือบทั้งหมด จึงไม่ถูกใช้เป็นเงื่อนไขนับ rep โมเดล TFJS ถูกระบุเป็น `validationOnly: true` และคำสั่ง publish ถูกบล็อกไว้

ข้อจำกัดของผลคือวิดีโอจริงทั้งสามคลิปเป็นข้อมูลจากผู้เข้าร่วมคนเดียว ส่วน label เป็น weak labels จากกฎและตัวอย่างจำลอง ยังไม่มีการยืนยันจากนักกายภาพหรือการทดสอบข้ามผู้เข้าร่วม
