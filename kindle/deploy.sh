#!/bin/sh
D=/mnt/us/weatherdash
X=/mnt/us/extensions/weatherdash
A=$X/bin/act
U=http://192.168.1.100:8899/tool
echo "=== deploy start ==="

curl -s --max-time 20 -o /tmp/raw.bin "$U/carousel.sh"
sed 's/\r$//' /tmp/raw.bin > $D/carousel.sh
sh -n $D/carousel.sh && echo "carousel OK" || echo "carousel FAIL"
echo "  size=$(wc -c < $D/carousel.sh)"

for f in pin_cal.sh pin_wx.sh pin_life.sh; do
  curl -s --max-time 20 -o /tmp/raw.bin "$U/$f"
  sed 's/\r$//' /tmp/raw.bin > $A/$f
  chmod 755 $A/$f
  echo "  $f $(wc -c < $A/$f)B"
done

cp -f $X/menu.json $X/menu.json.bak3
curl -s --max-time 20 -o /tmp/menu.json "$U/menu.json"
o=$(tr -cd '{' < /tmp/menu.json | wc -c)
c=$(tr -cd '}' < /tmp/menu.json | wc -c)
echo "braces $o/$c"
if [ "$o" = "$c" ] && [ -s /tmp/menu.json ]; then
  cp -f /tmp/menu.json $X/menu.json
  echo "menu OK $(wc -c < $X/menu.json)B"
else
  echo "menu ABORT"
fi

echo "--- pin calendar ---"
sh $D/carousel.sh pin calendar 2>&1
sleep 4
echo "status=$(sh $D/carousel.sh status)"
echo "page.idx=$(cat $D/page.idx 2>/dev/null)"
echo "=== deploy end ==="