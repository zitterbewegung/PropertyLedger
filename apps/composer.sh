#!/bin/bash
set -ev

# Docker stop function
function stop()
{
P1=$(docker ps -q)
if [ "${P1}" != "" ]; then
  echo "Killing all running containers"  &2> /dev/null
  docker kill ${P1}
fi

P2=$(docker ps -aq)
if [ "${P2}" != "" ]; then
  echo "Removing all containers"  &2> /dev/null
  docker rm ${P2} -f
fi
}

if [ "$1" == "stop" ]; then
 echo "Stopping all Docker containers" >&2
 stop
 exit 0
fi

# Get the current directory.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get the full path to this script.
SOURCE="${DIR}/composer.sh"

# Create a work directory for extracting files into.
WORKDIR="$(pwd)/composer-data-latest"
rm -rf "${WORKDIR}" && mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# Find the PAYLOAD: marker in this script.
PAYLOAD_LINE=$(grep -a -n '^PAYLOAD:$' "${SOURCE}" | cut -d ':' -f 1)
echo PAYLOAD_LINE=${PAYLOAD_LINE}

# Find and extract the payload in this script.
PAYLOAD_START=$((PAYLOAD_LINE + 1))
echo PAYLOAD_START=${PAYLOAD_START}
tail -n +${PAYLOAD_START} "${SOURCE}" | tar -xzf -

# Ensure sensible permissions on the extracted files.
find . -type d | xargs chmod a+rx
find . -type f | xargs chmod a+r

# Pull the latest versions of all the Docker images.
docker pull hyperledger/composer-playground:latest
docker pull hyperledger/composer-cli:latest
docker pull hyperledger/composer-rest-server:latest
docker pull hyperledger/vehicle-lifecycle-vda:latest
docker pull hyperledger/vehicle-lifecycle-manufacturing:latest
docker pull hyperledger/vehicle-lifecycle-car-builder:latest
docker pull nodered/node-red-docker

# stop all the docker containers
stop

# run the fabric-dev-scripts to get a running fabric
./fabric-dev-servers/downloadFabric.sh
./fabric-dev-servers/startFabric.sh

# Create the environment variables and file with the connection profile in.
read -d '' COMPOSER_CONNECTION_PROFILE << EOF || true
{
    "name": "hlfv1",
    "description": "Hyperledger Fabric v1.0",
    "type": "hlfv1",
    "keyValStore": "/home/composer/.composer-credentials",
    "timeout": 300,
    "orderers": [
        {
            "url": "grpc://orderer.example.com:7050"
        }
    ],
    "channel": "composerchannel",
    "mspID": "Org1MSP",
    "ca": {"url": "http://ca.org1.example.com:7054", "name": "ca.org1.example.com"},
    "peers": [
        {
            "requestURL": "grpc://peer0.org1.example.com:7051",
            "eventURL": "grpc://peer0.org1.example.com:7053"
        }
    ]
}
EOF
read -d '' COMPOSER_CONFIG << EOF || true
{
    "cards": [{
        "metadata": {
            "version": 1,
            "userName": "admin",
            "enrollmentSecret": "adminpw",
            "businessNetwork": "vehicle-lifecycle-network"
        },
        "connectionProfile": ${COMPOSER_CONNECTION_PROFILE},
        "credentials": null
    }]
}
EOF
mkdir -p .composer-connection-profiles/hlfv1
echo ${COMPOSER_CONNECTION_PROFILE} > .composer-connection-profiles/hlfv1/connection.json

# Copy the credentials in.
cp -r fabric-dev-servers/fabric-scripts/hlfv1/composer/creds .composer-credentials

# Start the playground.
docker run \
  -d \
  --network composer_default \
  --name composer \
  -v $(pwd)/.composer-connection-profiles:/home/composer/.composer-connection-profiles \
  -v $(pwd)/.composer-credentials:/home/composer/.composer-credentials \
  -e COMPOSER_CONFIG="${COMPOSER_CONFIG}" \
  -p 8080:8080 \
  hyperledger/composer-playground:latest

# Doctor the permissions on the files so Docker can pointlessly overwrite them.
chmod a+rwx .composer-connection-profiles .composer-connection-profiles/hlfv1 .composer-credentials
chmod a+rw .composer-connection-profiles/hlfv1/connection.json
chmod a+rw .composer-credentials/*

# Deploy the business network archive.
docker run \
  --rm \
  --network composer_default \
  -v $(pwd)/vehicle-lifecycle-network.bna:/home/composer/vehicle-lifecycle-network.bna \
  -v $(pwd)/.composer-connection-profiles:/home/composer/.composer-connection-profiles \
  -v $(pwd)/.composer-credentials:/home/composer/.composer-credentials \
  hyperledger/composer-cli:latest \
  composer network deploy -p hlfv1 -a vehicle-lifecycle-network.bna -i PeerAdmin -s randomString -A admin -S

# Submit the setup transaction.
docker run \
  --rm \
  --network composer_default \
  -v $(pwd)/.composer-connection-profiles:/home/composer/.composer-connection-profiles \
  -v $(pwd)/.composer-credentials:/home/composer/.composer-credentials \
  hyperledger/composer-cli:latest \
  composer transaction submit -p hlfv1 -n vehicle-lifecycle-network -i admin -s adminpw -d '{"$class": "org.acme.vehicle.lifecycle.SetupDemo"}'

# correct the admin credential permissions
docker run \
  --rm \
  -v $(pwd)/.composer-credentials:/home/composer/.composer-credentials \
  hyperledger/composer-cli:latest \
  find /home/composer/.composer-credentials -name "*" -exec chmod 777 {} \;

# Start the REST server.
docker run \
  -d \
  --network composer_default \
  --name rest \
  -v $(pwd)/.composer-connection-profiles:/home/composer/.composer-connection-profiles \
  -v $(pwd)/.composer-credentials:/home/composer/.composer-credentials \
  -e COMPOSER_CONNECTION_PROFILE=hlfv1 \
  -e COMPOSER_BUSINESS_NETWORK=vehicle-lifecycle-network \
  -e COMPOSER_ENROLLMENT_ID=admin \
  -e COMPOSER_ENROLLMENT_SECRET=adminpw \
  -e COMPOSER_NAMESPACES=required \
  -p 3000:3000 \
  hyperledger/composer-rest-server:latest

# Wait for the REST server to start and initialize.
sleep 10

# Start Node-RED.
docker run \
  -d \
  --network composer_default \
  --name node-red \
  -v $(pwd)/.composer-connection-profiles:/usr/src/node-red/.composer-connection-profiles \
  -v $(pwd)/.composer-credentials:/usr/src/node-red/.composer-credentials \
  -v $(pwd)/.composer-credentials:/home/composer/.composer-credentials \
  -e COMPOSER_BASE_URL=http://rest:3000 \
  -v $(pwd)/flows.json:/data/flows.json \
  -p 1880:1880 \
  nodered/node-red-docker

# Install custom nodes
docker exec \
  -e NPM_CONFIG_LOGLEVEL=warn \
  node-red \
  bash -c "cd /data && npm install node-red-contrib-composer@latest"
docker restart node-red

# Wait for Node-RED to start and initialize.
sleep 10

# Start the VDA application.
docker run \
-d \
--network composer_default \
--name vda \
-e COMPOSER_BASE_URL=http://rest:3000 \
-e NODE_RED_BASE_URL=ws://node-red:1880 \
-p 6001:6001 \
hyperledger/vehicle-lifecycle-vda:latest

# Start the manufacturing application.
docker run \
-d \
--network composer_default \
--name manufacturing \
-e COMPOSER_BASE_URL=http://rest:3000 \
-e NODE_RED_BASE_URL=ws://node-red:1880 \
-p 6002:6001 \
hyperledger/vehicle-lifecycle-manufacturing:latest

# Start the car-builder application.
docker run \
-d \
--network composer_default \
--name car-builder \
-e NODE_RED_BASE_URL=ws://node-red:1880 \
-p 8100:8100 \
hyperledger/vehicle-lifecycle-car-builder:latest

# Wait for the applications to start and initialize.
sleep 10

# Open the playground in a web browser.
URLS="http://localhost:8100 http://localhost:6002 http://localhost:6001 http://localhost:8080 http://localhost:3000/explorer/ http://localhost:1880"
case "$(uname)" in
"Darwin") open ${URLS}
          ;;
"Linux")  if [ -n "$BROWSER" ] ; then
	       	        $BROWSER http://localhost:8100 http://localhost:6002 http://localhost:6001 http://localhost:8080 http://localhost:3000/explorer/ http://localhost:1880
	        elif    which x-www-browser > /dev/null ; then
                  nohup x-www-browser ${URLS} < /dev/null > /dev/null 2>&1 &
          elif    which xdg-open > /dev/null ; then
                  for URL in ${URLS} ; do
                          xdg-open ${URL}
	                done
          elif  	which gnome-open > /dev/null ; then
	                gnome-open http://localhost:8100 http://localhost:6002 http://localhost:6001 http://localhost:8080 http://localhost:3000/explorer/ http://localhost:1880
	        else
    	            echo "Could not detect web browser to use - please launch Composer Playground URL using your chosen browser ie: <browser executable name> http://localhost:8080 or set your BROWSER variable to the browser launcher in your PATH"
	        fi
          ;;
*)        echo "Playground not launched - this OS is currently not supported "
          ;;
esac

# Exit; this is required as the payload immediately follows.
exit 0

PAYLOAD:
‹ Þ‚îY ì½YŒ+Y–öz™žª˜éÅYÓÝ£’GŽÎ*õ{UùŒ…|Õ%u.™\’[23«J¯b#É`“$“,=¡l@°5²ã1äÁøC äÁ€°¿,Èò‡GlØ†áCðlKücßæÂÌÇd×‹Sx•Œ»/çžíž{ïDî)¢*¿P•Ž,Îà/M6§ú¨4þÉÃ €&É'_ƒßgøÇþUþöÙ¿‚áŽa=Á8C8CáØ§I{‚bTÿµ06L~„¢O$Q×FúlUî}ç»ˆõëÿüºy”ûÓ—ÿÓ¿÷ä	ü÷› lÈ‹}¾+Ç.]ûj_ÖºŠ&û/¿ÚõÁP7äÑþËý¿„Åp2†í¿~¾¯ñ„LÖáÔþs72]©@¶Ž¿ 0œÁ1ðcð$H!É†8R†¦êÄ.-¹e¡•EYN©Åh"HÚ3Í¡ñ2ïÍ†òH•¥®<Šu³7bŠw[üÂàÃe“Œ¸ÓG#¾¶Ùqç¯+Š“n n^1¦,m­n…N[ìñ²æe8’‡cAUŒhÌ /)£!‹KŠa¢?ÿ9êÖò#±§LdTÉ }ñÂÐÇ#Qn‚f£ Ó" f¡/x§”õ„ô´4À”Ô®èh¬¡ª¢™ Âúór_6à4“ê†é„.ÓŠb¯o¥¶~¼„?dÍ_ˆ=Yì/29‘n6I!â€ÿ¿Ü¿0À_Ðþ¡,ñš©ÀŸ#Y}!¢V¬…Î ƒÓÐ.öxô…‰b‹´`l,Lªú¤ˆÅ!ŽÛA10¼ ÝÁXë†bê£zŒHfdT68 †ß‹kÑb,¿/ÏÀ·&ö3wMYCãŒ<ø½X†ËŸ‹µöÅó}~löt¸FËZÑÌ23¸ 0°'¿ À:¶ú-k’¬‰Š½ØWç| K2ì Ê[cøæ™dÙ„‘>õtH$ð˜]6j~'b”ýí6›—Š¶$'/|‘¢ª\%[8«kš,‚)z!Y’¬EêMiã£Ý":†ƒ€å¼&ŒU;!£@˜…6v"ÒJäGK«¸•Ò^sv^ÊJj¡—×‚>pZLÄp¤y(¶º£tá#ÎþÇÇ?X2ÿ,ÐQ@â0ÔÒÀ|¼“2VYëcÓóåâ°°cÈ›Jôd^TÊ¼‚x+¨ºØW4P·9Ë ]z·¨uôý—^5ìon4‚8ã_¿ö³ÿñåoÿÁ>àðß» ¬Î±Ù2H ké8‚ü´ÙSÔÁ[Ôbh fÏ›Xï¸%hg¤Ð¯;¼hŽG2jê¨ ƒF£ ‡ü,|TÑ&º:AÃ‘2$NŸj€ó<÷æ(¯Iv&t ’†CYt$wÇ µõ
ÚÅªUÅp¤O	”d±°nÏMéãnŒ2ø	RN{:H
Ò‰²aÄÄê–06 Ó\öO’;0à%‚|üñ1?$JÂŠ?þù’‹ïô±!‰~	—*¯ÍÀ¯²§ÙàóØîUv
|ÖÝö‚ßØ²Ó›/a%¬aÈvñÕ‘d¥w†ÒŠmŽxÍà­j­4Ç*/ÊnÂÖP‚ÕÀ¯†É›c„±Ã!ÀVfÈé#§(Ð°nFVhFêÀ$ò²©N:«¶Ž¼h¨Û·ªÆØ‚Ñ­š¬¬ªº3Ÿžet°%%›ãaVèV¸‰ìà²õVXXÜoýv‚°V{ùÉbh‡Ë	B§úXè2Š‰ò¨o¤Ìå(>wñ¤ñNÛS€JË¡ƒh˜UùZèè{êè¦ˆ='— [Æ]eörðàº‹Lž9©a;fhà7q}1s¨¸œ:T˜9m1aY°=w›yOSAg;&`=°‰3A{<X²¬ùZ	SÌVz
ùkð-ƒÅ¨X«0?ÐÙgéÂ_!‹Ö&Áð"¥w Q˜(ò¤„Cå¦q{Io‚îÍ`; ‘ D2&Uá5QF§@(p)\|Vü«7ÐPßrPüËÇšÊkL ÙV3€ fÍˆê¥²¼Û|H¿t²w{œÒ.sè6š…tL±JT4« @L@ò?FM^ ä­±lëbµz’|ùå—ÈWŠî(ª¼t_uc¼8cn;Í‹-ŠÙG^[Ym
ëíÛPŽ-¡Äj‡¼¢žÙÄy°He9¸=Ëð
s
¨Âì…“ÒOs½)-¬á}øç‰¶VÞ’æ¢9v›]QU°&p.”‘	WÄ2-o‘î˜w,×P;¦—Æ–…î?‡%èðgQ‚EàD‚´2²²É+*,V¶RÝDâc'þ”Ïít¾/ÃTìHP’lZ¢3ºŸçúˆw£Dwaxc²ÀÄ*è0Ðõ@ük«IÞNÀ„#ÙV[^Þ¶ãÞéÿ`Ù0{ n_¦7>0uaæÇÐu“æè_ €t0E­JÝÅä2k?ºÄÐ"ÀÕÐQàƒáG‡³É7ô!Íõœä~¸³R¶g 8…™—m•¸ì«\µþªÌVZ96ÓlÕ9OêfÐªøKýc~÷[Ñ6°Þ°RA"ø¥ƒÿ/a±_ÞyFÖ‰ÖÄ€yÉèZ0L—ðÿÌiñ
…•–¶ÇK6·‚¡dQp[s— 5ôŠ†ÅÕ­ÖúèÕó ¥ƒ$ËC°bhN!`ùÉ »YÚA¬‚—èõXo{â& žño þ™	Ø¡þáßýìïçÉøï‡Ð%ŠaXl’U Â èÇhÃªåE‹u¥Éé*`gdôã82êdSüX5bå1.AJ¤ª:`ß€ ûÉ¹] eåb¤±o•àI	K¨œÙÁ:h"oË–JVÐ•¯]Klà,E˜»Ú˜l·¾17`3%«ý¾Öƒ5eE¢0ê'pŒL«Év`¹þÖÂfx-SîÄÅ«¤˜‡_ÂÌ+}
ôèº¢ìn…wÊÁojü-hŽ
››ürííÉ2Ø§¸ÎxÑ]8cXÚµvS»½m»ÍÌ^?}ÞÒœÙz°¾ÚÞnoo7ë+£á_Ü^óó¯ƒ–`Äý‰þäïþÅ|ïÉøï‡ËDoÈ1ÑÔã(ÙV	k’£^Ø†,7æ9Ðˆ,{3JÄ0ôL°ïDíô	,b¦-]ÓMˆ=¶¬ÛQÀÜÉW¢<4!ñ
íæ²HhÐ3§] òŽ8€¨gx¢¼	’ÂÔ˜Z:Nc¼ÕØÕ¸c 2â¥b†«48hŠs2´4NùH¾+PGŠ™Ca¡R òSKúï:kqÐ‚éHJÛsÔÐ;æ”É°É…±é/·y ×Þ`Ä€þ³Ï6ÐbcM³bã9,¤]lª­&Úfëu¶Ò,r´ZG3ÕJ¶Ø,V+à+‡šˆ+Ùç¨FÔ#_G°ÐžGh£ù–e_\Îeej‘ kZwøÚ…êšf™s–Œ ²0XŒª ²ç0¿•~ÙŒ ±HË‚ÔÂˆY³í|?’ÀÈŽ[Á¨mÀ„qne`zä…Ñ<qAdm<@ó²UXË:ZfKü›ãÜ_Õf«CÀpñŠ¦ÏŒp0/¤:Ú #ºe*&T¿,zÀ«Þ˜Žä^Ë
„µõ±Ÿ}IR-+¾Hât¡kÿ	Ï­ñv(À&ß—È0&è™#â[Ì×óéKšjMÏ¼¾dY Ð,b$ïÇ"RP‘µ,õûFS€°ðñèXÛÇ=][3 =}àDûbYI²P˜wþ†5É×O»AY €50=–@Ø±R„V;´„ø`Oá¾Ñ	-ÜJq]á¯eW…[‹m2K®2 èfº]¶’›Îß°‹Š9­_ÔÇTuCX!~…GBÛX*aQNãÖG×Ä%Â‡IAÍèRøJ„ÑÕ KrZ¿ªŒ‚wÙ¼°ÿäÛÿñÿû×¾ûä	ü÷ž‡}9,>ba»ãG2!h’>2ýœ*fó™ð8gý.) «0^¢­þ†ìdXí
Í¶Ðd¿òO¸Ót9éàÖKØƒôF¼xñ 	Œßò2û—Ÿø†ÖÏà.­€	ø›áå¹°ÌEûd;áÈ_—[S€?¹ä:Œ˜YkS)¤v‘p‡¯áØBI2l.L}¡uÝ+¬ë¨Û`·Ÿ‹Ž»=uÀðI`å‰f]†è`¬§\_üÕÊïÿ5 –Ã?]R.ŸÍ%¢^õÚ@ ÿµlb¨…RVmîfÐÒä§u·4.(`¸z•ºlØ%×RÐEë!˜ËDh5×Ò<Ö>‡ê—Ø—µ—õ:ã§{R¬¼bb¾â$¯¶+\Ý”åJÅ®¾¼b›w`³Ü'«Y:±L¨H€î€ùµ1Y´÷˜‹Ò‚ˆ¨÷BˆsÒy[àƒ#7º³iíÇCsXÆª³^|m…y¡ ü7Á
´Ö;¨ ¼göÐdcµâàŽ¿ñŽÖßR'Ð[" þ-{°=ç±Y/9Âràü]°âÆâ´Û*pÅúh¯mZn9&g—ö¢ñx³š­¢ÏJù^*£˜Ëý6Ï(7{w¶å×‡‚^Ãör?`óaÙ ë ½–}ìGlÚˆµý·÷6¡
_ÞÑX™¯n˜õES'J¸æ1¡ÄpáÅR	ŽÕ€` ‡Êž»‹q
ß%@onŸ¿4?÷þÓ6øƒÑž<ÿ~°äÞ&FL;bÚwbÚÎò+[Ü2D«ƒ0Yö¤Ä.¨½g—
ÒtŸ?‰ãVÂÕF^ËtÊÓnµV•’.Ž-¡ù$AQq|É}›üUî[º¬·^<a›Ü«R1_h¾ÊW«Ù†Î5ëÕÒ«[·™*˜nùÉ–š\½Â6£}•ky"<Å¼:á
ÅLÉfÜ\«^%_]K­-pìÉYH¸Ûôuñc.SdK¯šgÇœÝ©Û*±yÎMe¦[ößrµY­gÎm*q™f½˜yÃ—Án¡¾"e¶TzUl”ØJÖSç2U Œœ…6`u†¢KµÂÖÏìJË\=ÏU2þôÜi†+7a¯Æ¥ _ðñèCà·ç9î~Q:¼Zî¯ö„)üÎNàPÑ°‚.Í,ok_äMþÊö¨²¾|iŠš)w­m.À/Ær[¶šÂ’ˆ3Uk;IæŠ‘-«!)uÂ+‘ Ýxà³MƒVV;¹1 ¡•ØcUí4€X²¦©‹$ÐâÊ´D„pÍxÚ“eÄ¯™/52`^ºú‹"l/;„Þš¼4Óyº=à¯*²y¬O=ñ°ûý¶O›·Ž<\_Ì±C]Ágye¶É£¨5äÑDåÐCØ{2ëpêˆ1kA¹kÂôú‡AôÜ1¼¾dÜU&·`r0Àc"p—f _­‰¦>åIÀ¢•n•´¥	vâe•¾îø*4lþÅfÞP{ÆCÙ_¥4R&rzæ)xe ¾ò¯
ïWOô~iú•?òÕP¯Á¶þe{£­R7×‹±¤w9Ë8îZl\NÕýÂ¶0žåoC:Ö:S•	þ†i0rÔ#?¡‰g]‘ŸïâóéŒàm”§ñ}YÊ>J-MT>§Ê²¶æÜ4p.G†#¬„%,éT…rP¨1POè¬y¬¦ßâÿziióŽƒwÚœ µS¶k{x©ÌªŽêÑºÐÀC*û*lÖÃ‘c¹ÙEB@u¯Ò	Zg‰LN>“›Â­där¯šîU½Êº6Œ:{|l l}Üíµ_#‡œÖÇ±AÀ-5q‹&Þ¯€Ê	]š6âÛK/Ý2KWcÍÚ
¼jÿTüéR¯?îM©‡DÜª’ ?òÍ¹òˆÝÝ°6‡ø£AÓ%O½v×Çùk‚_;íÖÿ£ðÃï>yÿíy´SÇ¸i¨‘†º‘YÙÅ»‡0,ßq7mÅ’ì³»z}0„ÒvRÙ ò»1@{‘·DçHÐCq‡~ïxçÄ“[€[ÑWÁ¤Þ3J7§öhOî£H®‹?jÅ­wä‰ª¯±¿ÿoüÁ¿xïÉøï='…oçêÂˆ(LDaî@a\c©¬3³ÃÆÿ =?@¿ºû‰‹×ŽŽUîûÜÊ2À³8¬jüßq¤3Öœ“/‹<Ï–??rÜMòaè°1z÷ÙÓeôS€ÉVü„]âá9Ùú)Ú•Íœýñ¢º_i¼*ƒÈ§·ìáSoÎëóù’¾Êº‰'ÿÔÓ>{à?uÛÓäiÝñL}Ûö}jwê¹g,bÎ†ƒÓë+æ—=A‘žôþ8o.¶ÐÞÞ{êMáÛŽó•êY)sµWÎÁ€ž2=ýò²‘îÁ;d³èr„Ñ³ÜyÇQÃ>Z$»û#–C/hˆ§Ù:Êàždxf·	ÎþXUgµ1¯Zš©@‘VV1PšölxÏ‹ïÌE6œjÜè/IvÎd@x½®ØgÙ…½û.œûa`OÉ7^V‹Ý§§‹ºÞ}7Pˆ‹ 0Ý‹*ë3¬àM:}â4žy(ÁiÌ»¯ÁåþVë†­;Ó–•¥×Î¦™wWÉ¦4+IoOpVŠ|¶J~VRýÊP!ïj‚çµ–³å__+=Œ…Q5©ìßVïBk,Ð´]aÖ]I0jÝ¶š~€>u] žÂöî»Åµºdß}Wé «3èoó§`L¼Þ
OƒKÞZ¬ns×’jÀßŸºÍ{2Ð†à¡.¸3¶²×wØÂ¼¹@«ú°BAøe,ùƒ×€òt5_qtÊtý5
td fun3;~×‘•ù çùg×¢èrèŒ°nDqO~0Ÿ}±Úû×ˆm‚£Ð:¤·`>
mM »Ýq\Óök§Í6…LX0§m„ZÏ¸¯£4«,ý¦ñ´tÁ5l•× †ÃÞø¿ü—Ñ§·èh`u¼ùà¦\èúá7”háöb¼æ´ë0ÁÛ.o]x½¾O€ ª®Mß‡{ @ ƒ¶Æ§×L²[nl…õ‰·¡²·©Ë²*ßQ@½/6/*_ì_„"Ä"öf[Îll86zÏÜ®iD&Ùõ¯!Ò.¼oWàãÂ^îë°z[Éñ0z·Ž×¯æuü'×5&L$ r¼­¼'¤}¼ï½Ž§†­ißÇµËçY¶Îo•1d¹XÔ­Š±qkUþYé¬ZS¼oÊl¸NMZ)å&m)ÜÍ«4…y;QÖ/ÐÞ¦ÄõeùÔªð"¼ÚÕ‘‚6Äï´'Ä¿ü³OžÀ¿éXhtŒLƒ‘ip£ÍËdmEÃËn©¯/ìÜ¯Qcaò¶Uò¥	üÖªø¢ˆg‹_¡ª÷"öWFå†QÖ®¤ÐO%^ƒ²³¡tëÇß·„i^ã6~xãÔþ9êÃ¿YëÂµfeævVP(ü¡)¢•FäGºªhVy#¸‚T+™Þ³rtþ1u+ó[±²ÿ/ñ§fO×fv:aæ¹M²?5þéËN{´¤%ãzj]Cóôe€—=­è„~¶ÂáÂeÛ§€µ‚äOqŠ&™dŠ"Ÿ>OgïîÂ¤ÓžbÊë’ù4%˜ÚÑ”Bt;ï×Ï½…±ºI?hŠHT2u‹~êøÁ»±´X>_J'OË7­NÕñÌ÷]$LŠ‚ÿú½¹“<DÜ»õr]±+~0OÙñŸá5}À«³!Z­ýú&)†&	OÜ¢#¸¸î;‡wm E	ÐÄu‹Š:ÚÎ].ÇêØÔ7@¥èE=¹EGhÙßy¬*àI'oÑD(‡hoÙ‹š1ÙÒsäz§ƒ©¨<ŠuëŠ© "ÿN3I’Â	’&o×éÙ$cK*VW¤nË v¥k 	—9üw3©~”Už 3`5ñ±Ä;!žÇ™Ë¾£¶§@w9–2>@g!ß„"ÀÍ}ÝŒ Ý©³-Íä¯€&àv35ôþ´V(þ7ÀÉ$ES`Òo1å#=„ËHI€&™7&§ÝqžHï0Sˆ?üµ-ä.$]ÿµËKk‹µ¹ë1ºqV$ÔÝž¹ TAÃv%‚¥_ï!à»÷¹U°ÇZàk¥mÌñ9)mËhœÕ6åSìTù…¥¤ÄT h˜=ð}pàiã¢ŸÚºÌgÊÒÖ€µÍ_µ²úïE»íÞ ;áë¥Vµ¼ãúšna–´ø€Úcèô¹¦ÉgaÅ,-šž+ç<{˜Öæ²òµÖ¯E“ê7ú øÓYûm‹ÐÛ9$„½¶@i†½ðaÜ­*ò¢Üý
K
»Æªª¯ãôÐêŸ)oUMÂ¬©:,©Û?Âß³7í¡ß¦ô ¦+³C˜¡Fˆü(/IÑ˜?vA•kˆ ·¬ 1t“f²§µ¬Á>é©øÑjÝÞ™•ÃÊð©/ýgv1k6ÏTÓ*`Õ­ÑéMÞ²bï@ZEx)êuùnë“¨æ†½²Ûn	¯#âÆgîüq‹Z‚[Ö+mõÆßuóõ6[–NÒëv*×ììÂÓ›pÊ &~.\—Û=ë	‹°ìîeØBTÈ¨Ùw/ÐÞØ
Á—OµEÁ­`Ž1ì¶{Ö«GZV›³’æºík›½Íõk—ò.î®ß^Ükoýö#t}±°½f¸oÞ=_Ÿ×I{ý~9·/köÔoÐ=ü_SpcWh˜ø%…O‚wÓþIÿòðGOžÀˆ³=/Ïˆ6£ÍÁÎ,Îvú®GâÁäÃvú^'
nB¼?(úÚÍ<@ê¼ýQ‚ÐüÏÂƒÃ„&õí:ŠãÑHÖ¼š…½™Y	æS7i7ÒY·YºHàœÇþtÍ(Æìøe.X“ÜŠ^Q§×§w,<–á¹«îòÕÑÐU¡Õ©ÈÉ‚BÎ	-¸fÀ[´ržýÜyM‘÷`Ì!ç#®«h1‡waÌv¦;Ö´‰`å¹c=^`æ¼én!í]+Ù¹¦¦5"Äš†~´b ò«æžù¼Ë!•güŠëÔÀÖ;öùiX'×ú‚ÔÚ{2úµý°œóåúvxƒnïÞáÉõÌûîäáIà£¸ë‰ïãf ô€Á-ÇÜWh
?ú$tN¼É,_poŸb×¯i{ân0Ò|°Í¬ów/=xz‹v>0…ËwPÊãE+oðÝP+¤ªgÁˆ7‰jñ¸{©!ìÌåXv<_aúKŸo ±Ökž+{•¡jþÓ—+ý‹-î†ræÆÝ­xœG!Òo„óV¯+<Üf~vØ¨Vb†ub[éÌž]Þ
µá9<c¬šìhÄ¯}³Ö<F™F²(ƒ*%»~Ô.â%
¸L ÞÂºäžhÇœ‡þÅÑ0Û |qjŸ²^}ö´¢/¡:ð¶[çy
F|Íô=GWë[q¼^1²^ççæM7é@â‡Ì,ÌTkÈ#ðœ¹Å¶AAÅw°¬…aõÊ2ë‚?¿i77{z„äº•”âÉþÙUˆ	Å/".›ƒo¦Â}æ+1V—E}$…©ñw%‰‹áY¹$ÜûŠi+‰„™gV
ôˆa7˜Éò^ÉRº;×¶Pr-AŽR¨ÙáØ./Æ[vÙ«‡o}û·ž¬tÝÞ'Øƒ9ƒïí.á/~ÏóúîJ…×µ–ðïì­¼µÌ|½Ç†òO<oùø3_óYÂïþdåmŸ`æà[
K(þNèË
Á‚Wš/á;ûk/8¼Yu	ÿà£à=«Á¼Á{o–ð*vÎucþ]ß˜ÿÍ_¸×`øs/ÂXÂõ‹Ðk1‚ýä—ð¿û½æWæ:`B[Â·^ƒÚñÑ¯}†~ü÷ë ×O"Ø:tT}jXÄåÍÕ IòÉ×à÷Ùþñß•¿}ö¯0(,A%žà	œ!˜AÓÌO`öÅÞ\“–0†Ï9 è	ÈH#}¶*w	l?ª¥ô±¯X¯¾J2)&…#dL“ûKg£}Óy¬Õäo°Ê²
ÃËÐ"he?ç8¬­ÔÀLRà)<&´@ß¥‚š%ªÞ\CªCRI1™Œ%ñ””
íÃT]ìËæøj¤¬9ïß:©æ0‰7`È›=Ÿqëjëh’7…õšôÀèÂT^5äë›˜”ÇH"†Ó<Ï?pmùÅj¢±|˜u³†|‡$ŒŽaT¢ƒ=tKd,‘&d™çc<%Ëá(»#ƒIÓI™äåNL&O†µÔóÈâ‹Åóª€Bu”îµMI4ÙRí€$
7•¬ÂÔÎ÷¦r…%çùÇ¥¦väåÛ¬/œ÷~¼%À‡6‹Yk[oG¢2PèMë=_^“ô}ýØ(FH€êË‰%3‰äõó‡ú«œß@²àžip¤@+'v‡¯¡¢ª€¡	f½8I{Bf „Ny1BªÚ~ÐMuÕiuŸR‚@‰L,I’)ŠðT³H‚wpK‰XL e9åà–KÇË/®Ç¹”,¦$‰Š%…¤,ˆ×®>6yx“)20¼	‚ßë{-JI2ˆ‰I£¶‡Rëéúú.	,F:MÌ&H•LŠ4ÓItb$CQ|(NÉOP$ A©„œLl†S‰È†Ç€–ü+öAqj“ñMôÊø&húîHµvt½–da¼J§oÑÛ…9nõ^&g!—ñd´¦€¬Ûñ3hñ[r$_|ßÑ´…¬ÑXŽE­àa2±Á8a`éË"“;$6N®r“¡ò#¯`a0ŒPlÈÏT‡W{YfL+í3OÄGŸ|®ÁÏñº/ÂÇKå+3ÖUuWc²&uE3¡Å7¾¼OìéçšëuktA~oÝ ¹‡cŽ	îmª. ºbñ¥“©Àø¦6âIB„dª#0ÜOYI‚H¦pQXG"6ä)&Ùé`£y	_çŠvÄŽû.pS*âªfMÙšà¦»äÀrñFä¡Ì¯ÐqŸ‚Ápw„Áµ$Ê8˜*šLn2Wx‡§Œ‘c)Š¤;ÉÍ&‚$’)bRŒ& í}I9Ÿ±EëéŠÛ{j¬^[÷ôÖ«t5«o±Þc©b«LƒJ­VÃSTŠ‰á8A&BW«L&;–"0IÌf8”CpÄö	¹ïb…Ü¯v|ucß´·8NH§‡0ú•![&çÐ¦ƒƒþYÚß=‡f÷íMÎb1‚ïÚ›³`8ÜY%B+=•»!¢G‚!‚äa#J.ÈIY5Fò0	›Í¼L‘#%Å˜DtR‰o.™›‚X¡Ó)l“™`1IÉX"ø&ÖÙl"çœ&b©”ÌP¡]2-ÿJÙØh:,ã»uáˆ7v ›=ÝjÂqµÑô³5ÈºpáSÕGêÊÜªF˜ðLÉ‡_1!¦€XHÇDBîPbz°‡ÁC¥ë€dp[áz%%ƒ¯ÒŒÐ¡¼ÉüˆúÀ¢€a«õ®næÊ‹›l #vœ ™Zæ%º™\Œ§’4™Âc¢Ø±·Œàâ©Áˆ!6b~Ž É$K¦RrÃ¹ †";"¯;I<ÜØ_š»¸ŸÏ§¹yîI.óP#,`X‡ x¬ÃH	|Ãò+FtñÛæ6¯ ²î"ÝµÍGsWU ñ0¸H7ÃCRJTRŠñÓ	e|oÑÝLã$>EÐ8pQ6¤¹IšÂdŒ‰YÅ:oŒæºÎGu7b9ÉKÖc¢Lc›RÝ`!¿úT7|0¯… ¶î"Ñu]ƒß(ÙÝƒët#Ddpž§°$K%*tÿðLv“+S‘Ä7Ò;:ÞSR2–Há4½±ÞÁÐI¸±þàážAw=‡¶D{«(¿á8²L&(RŽI’(ÒÄfã,äWŒö®n'¯Ì›vyý(»‹Ä7tëàÈ0õP8\¶›I¿KqÈlSÅ{÷EJ¯ÉÜ%¿!Ñ.íìKßms@¾³ûO`Ô«WCEë¾zšÀÊl˜£ÀÆÀóÛUºðÓZd\Îw¥õd±Ï«î–/q‰àE­Zª6AšdB¦H:ÅÄ:X‚â8óüÆÜþ-øÍ¿@Ñ<OŠ±‘©ÐMÇò¢‰Õ;<lèoð^ðüS½¡®u×‘»åNëS€ý:Äþ#g«®ácsb‘b#Ì
:!E´l7iI®š6ôLåNáB'&HIœòÀéYÐb#´*5OS2F­Ñ%£ýq7ü¾ûãÉÄ*æÉ0G¢e 4á"Ð?¥Î†3(c{œlEÇVEÏ5ƒwÃvi`Ñ}SxYˆo™uè¼	¹ü$a#Ü =J%D:&3î$êÔ¿™Û±ã(ŠÊð\kP/„åzÜÿ¯9n`S—ïÙ‡ðWðJ²k\±od
, ™‡žî4ÎûÉE‚ÄÉ„@Ä’&¥ÄÍÒkë¹¿Ún÷âÔüC*ñaŽ¸	*xÈ€`6XÿÁQÝŠœeûÿ=†˜u÷'¸¹À*Z–w?©ìþm ë.M}@90±â” 1†Ú„àŒ”S Éuh‘b˜°%R¼„‹)<F`–²üeEgÈNS€ëaÔ†ÃúÓ9èëïyíý'ÿ$-$ŽæOl`\ï‚~=×ÛPº2ÆÂ@1ÑåyAÔ¼z³Ü/É"áØ‘HR	ŒÍÜåÈßýÆÉy¼Ñy§úMUjÅWžHn€Rë)Ã›ur·X{ÙèÂ‡^ÕýöÈ°¡ážwä¡Äë¾"’påªe˜Þ–Í{wÌ±¼¨-,ñrÓfÑ$+QQŠ¬ üáöÜªh’|Uí<{úÁÓ>ZÊænÉ÷Ð):(¾l(9/nDËüàW­¼Hµ6ÑâržERçòïÇG¦‡E§ í2Ao${Ï-n&NV=¤hàw4Ä^y_y ¤HÛrN®èÓ8¹¾Üx©9wÅÁÄBzâ®;x•g	\ô]‚Öîñ&¼‚Þ8g+uNYñésûéÝÏ5Û&gá·kûÄÚ“yèêC45É­‘ê°ÙpF—dkaøÍ#_}®ÁæîèMŸï¿¼Ç¹©çnaE%Ÿï/Ã(q%ÌóhûJœ50Ôó¦oQòGÛõÚYKl†Ë‚"´×‹~îØ	®5rÉMt#(ÄmD7Öû•¥‰U÷jÉ/püí›(#'©U»æ<á
Õ¡xQ` .bjÓ¹­s&ÊÑV½„f¬{GÆ#>XšKk‚ Õú)¤´JÇ{2ˆÊàÙG9$n°ÅPÖk — œ¼1óçûÎ5÷ª.òjO7Ì—$`?q~¨|¾o—Ê Ö”ØÀš˜îAŒf•Ñä-Ž“Þþô§ÿ˜qZÈW²x” ‹ °{Š=ý0S-W\ýUšmp¯ ‚ø$)Ü_Ýâ‡CY[ñàrcÈOW6¤ X:
ºÈ™è¶@PN›(#]@~ÂøDÁŠ±ƒL„»*nÏ+ÏÏf©•ï[Îc*‘”\bbMãÌ]Ž­¿WkoË¯<‰Åì¯¿¡ˆ •èü~ùù>|Ãôóý×!¥»t^=çßL|§MÜwe…å=»™§C‚Lðè³ÔéˆÔ†º'Íó		ÌhŒN%¡Ä:œçßm2ßÈD2hÔÁ),F„®œüˆyö~ó¸¬ÃÐ7ËÞI&¨¢2ØùtœIƒ·‰b|G
=årÛÝÄ›ÇÊÚS¨‡ìi½ÍÄÔ
:‘©·‹êú…‰|Ü|â[^)âIž¼°ÝŒøƒ×oùd(jÍýŸX÷&(O$¨'N’$þ¥¼%!ð–ßÿ2ÿ¯ {†/Õô¨Žæ'	Î?Ðƒ(š 10ÿ4‰'¢û_·–H¿Ÿ•'²ª-!Z×Ô¼u]šÖö…Fƒæ,t±”¦‘®î#òšñ‚eGsî–G%@Á­ß‘l±þéþ‡ÏPQBáa½ƒ¼ÿáW@w(¼jT[õ÷öÅë}ô£}ôç?G‡S	üBš…bãU#S/7?ýÞîdÃö¿Dì×Çšõ<×Ó¿ò$~ý6Ié Ÿ¡/æè‡_åØt½˜yuÂÕÅjåàê5úÅ'°©‚ÚÅø@}p¬²ù>Û0À
ìË3ø¤˜>2Q†O»5¨¢®/žq0uÐVhlG	ko£ÉÖ›¯šÅ2Wm5×·Ú—,¬í8…>3d0Y’ñÑJ|¹?Å)»[ŽäOŸþ¥Ï°©/>´þüúÙgè‡¡úWÐG2úÅ¨ÛJÖ7õ%ZÑM”Gm«ã>ú~N|§˜(óÂ1¹¡£Áõ%p† @¿×ûq‡ÄÙ(mÄ÷ƒh’ìû±hÿí‘Bè¿-¹eü²ß}¸ÁMü'?ý'p‚Á#ú¿øàgqAÑàÛ=Ä~Ý€`{d†·gé|# dýKúTƒÓióúï¼þq†‰ä¿í@´þßnYÿyéþuÜRÿ÷®ÿEGúÿ6àæù·4œ{aÁçŸÀL4ÿ[ÛÎ¿k
Þî>ÿ ¨hþ·wžÿåk$=^Ód5f^ÝTÇõï?aÅõ?##ùo+€ü?ßF^!_¼óí÷¿÷Î?ù[ÿüÿÚþÝv&øã_Ê	I’H%;".âdŠïðò‰TŠî)‚$^&q™¤É”J"O¦¨T
˜$EIŠÚû¾üþ·‘`Á{ìÞŸA~ƒUE´\Kö½wïVG]|ïÉû"Hî[ŽLe<ØûÉÞo!{®Ibþþñ­½ßÿ–¿¯¿õÎ·–åìï#ßcá5ÆÞoïýàïì!î÷@—í_ Í¯·GŠ	ï§{ß‰Þ]xÓÔmw¿e'ÀMó±ó÷vmì™·aóõß•5ÙPŒ˜ êbÿÚ:®_ÿ8™ÀVÖ?EDë+€ì¿&òJÿ£ÿ4õ7ÿÊ?küç~ôéÿæ?éýkõ½ÿöÿþ£þ¿ÿÑ_ý¯ÿç½G~Gþ:ŽÌÏÞùÖ¾hÅ?²hÅo˜²a‚å¬hŠôñ/I:‘LH2ñdBbhFÆI,A2‚”ÀS2MÑ˜ hEŠ)‚’©¤Ô~ªÃ'S„” ? ©Ø{ï·Ÿòÿtð;—¿öO“¿÷áÿÞß»šVÿˆúã¯ÿåpïßÃßÅöþmlï¿ÿ	òËUdìý×?ÙûÝŸ„-°½ÿëÇ{ãÇ!øwüþÿñòrãxï{oïOßÛûÞC~ÆÀ?ùÞi._¬ ®Þ,æŠ¶ÉY¡H¹XÌÔ.2VtÙi1Ív‹µì¡Pí%“­S=LdÊ¸hMÓYö(Ýí^öúÕãZ-Ë^¤çåš1E2µ³ìI­–ç¦‡'­9×,ƒŠX¼ÅeÒå£‘3øöùDPÃ³&×.§kV\úª\i¹q‘;Ÿ!gmê‚?­\sî¼œíÌ½rMHjå¥Êùœ)æ¯ÔÒ 2šœXNëVöªÜ<#¸1ž•sSìª2g‰òÅÙUù¢F•/Îy6³Ãj‹0¤\(_eæìaº[9I³gMV=i–ëå)gw­ÈM‡Ù³öÕð|š	µW®ŸMs¬Wà¦xtìÖµÃž0¨E¢2)×ûÓÜÔJpÄ]¥AÿÅ«Òà„<kãS!ßŸ)³\ŸNó]+Má®*g*<a®?å¦g…#ý¼8¿À2lí¬èüÎ²51[ë²Ò¯8}–Î&û}ã 8?:œ¥Ré²/Åîœ2§ÍË³¡q„ÏÍJ¯ØÊUC•M6W=¬µë…ƒ¾€ôæ¹\eÒÀ/§9_oÑ !Õã+r›fa3ëØ1[+ÄÓ,˜ûn~Pf“p¤C0>eö,¤sðƒf§Vâ¦¸5e§\:>g‡pp5’+vkÝ<oª—ŒÁu„É›ì%9@Î©iO'éI­xªÏJgZ¿Ó^’ÓLwÑ_`h¶Š¬³Ånf6ºˆ«­3}ÆsÝ²‰\¥’*5?PJ-ztÐ’C³gó£Ò¸›)æOU±EÑü¤Ýh™u6¯%ÙÉP ›Õ+³?:*å&‡Ô:åä‰Ñˆ#ÖÒà*ÙÕå²ÿÞ¸šòp5‰w5ÕÙÊ¸ªTfR<Ÿé§Œ¢s}µì×Tœs%¤ÌöíÒ+gNNÊWÜœ­ÛhÙmfú•žW ßÇ|›»Ê]°-;NlfO@œ’Î#â °FŸÉ«|“=µèM.ŸšÏ¹ñùi¯'œ¦óu!ØU!Ëòvšr“#*=¤4M8-ôÄJ¹)N+E¢Ü,bÕf‘hÃ°+sÃöEZ€”aSÂ€¸”ÁC:å4f/úé´PÖäÛ¾îÓçH9]Î§g—ùF™L±].ŸÉ8¿§\ÅŠl:?N]¥kx¾Õh–OôÒ„©œ*gGíÊ¤³=¤]o¦Z©ß>aÔz«sÆ±G9^j(
UfÎ™óá4›¬4˜¢Q–Žëô9ÉÍòÝéÑE³™.•Y2À•‘…ˆ?­Á¹-t³lÙZ õrší$9ö‚eËÃZAÅi­_Î±Åô`tÎ™t1BFõRz4¸²Xä«Õ–ÉÑe…8¤
$ÏË¬¾è˜º‹uÙ2×ÊkÒ8ªÑH†ë^
Í3™LòóÕNÅ{Úù“-RrCk·¦'©IFŠw‹ÝuDëƒÊáLÒs:7ä¹â´œbÆäô¤\8æ1e–!SÌDª´êì§×,Œôï6
,±÷=øŠ>üïn\(,d;¶ÃMN›x=•¾˜ãt¥rŽ©õŒ6[e;Ä£°%^•ÛRþjŽ@ÞsÖƒÀÀrálcÖƒ@Þ³ëIN òîê
›±Äå?§½Îü˜kX=ÏŽWi¢tpŽW¦Âœ·›-ñb¦NrE=Õ.}Iƒ(Ÿ²Ê%‚)í"MæZ<y^ŸªRêøt„úpªóªFßÌ~—ÿÜ…ý0ç:Û9È°)ã‘T‹«Læ§UÂPÉB•g/æS\d¤"=Môj—Óµì§Ä&dªŠ#c.—¢e|@R]jZ5Ò­ì4§µ»)eF%ÌÃ$Nõ3Eö´Ä°“¬Z)ô	™ËWNºuÞªŽÄcDÂ:Y¾Óït2ƒI’p×¬²…Â_(~~ïÏ•ð§{ïì}üýö;OÞÿ¨½9Òß"¶ÔðnŸÃÕo—c¡!þùqÆÖ‚3p·¾×ªv¶÷tï7nùŽÛö÷wÒÙ·ºÌ)i]Äþ¿¾è÷ÞÞ; -ßÝû6P§¿wC¶½?ü)l­´÷×º÷¿ü‚8Ÿ {ÿô·Þÿ»Žøü·ÞÛûïíýÁ{‹xøŸÝHÊJs@Ê$~Éó‹frRmJú8ÝžU8¦~JKq…çóÍ‡æù¹,Ûpy~†®{qš³	K–›RpÉ[”ÙDj.æéR.d©ÙK¹›tÕ¦\×!]S3HOËé–K«øz%Š(í&ÛLwE‡YÓKÆQN§§•ËÖŠÙ(ÔÒs<W`Æt†><ÈåÜEIÑÇd{r$¥x¥:ÀŠÂYá@`ÇçÊQO¤ÙÌ@Ec˜ŸšWç$k$;íùé wØUŠÃÃON‘Ó&[µ©LÒâñ[æÏ\Š¤‚éœ¦»güÍfÙc¯<n²˜âåŒ…R¶[SÒ™4/pó’fã]…muò™“†1ù¼~	(ÐÕ,{–kè½6[<ëÏÙ#ÄÇ(»•›Ms¬Â*§ò¬|šðf¯5œàXS>eÈþiH]Œâ5cÐoME!Ý²PU‡˜QËvðx/­É=R•Î'Z©]¼8$ãb±¬6â£Y‘éõ¯“öÿÍM
ÊÂBP®Æ‹ÅÖ V—J\²T5ºã^}¾Âÿ‡Îÿ[åtÑåÿ¥ €œ›³'®€œTz.D«*Mžf›\¢œ=›U.¸Y%ÛŸUT„í°ì"lzrÁ•ÜåŽlºÞÝåŽX2þ{æ4È¹¾ÐVÇµüíX8âU!ç‡‰ù…dJ;wlNº¼z\:&ÎòFs\99ÏÖ4­!WJñƒ~[©µ†r{žëgI$]/Éæù´>8Oá@¹º¬Y-©d.úñó
K7Î.+•2g„°p™-³S[PælA9SfÙé‘½X.Ò™Ú´¨³ÝöàªLéÝÚ1Yìæ
W“®Ú0íÞåÐéÊb!Ò­ËâI7“?,¯°ê(°^+öØ2?>O“ÇrþüD>,´ûÍ–4äÌäI':Åé€¿</s…«z½	L7Û$“ùB¾ÓÏ”"Ç°Q›MM®‘êáýCÇˆf¦FéÉÃyíÓ;ÉÄÿåk¢Ò„Œd¶d$åÊdPj§
3.ã©tIêñ‰òŠT2²Ûe$ú4Ï:Œä*çÊ*²©	¦œŸZÌÙÔã2d)_ËLx Ž¹Ì¤Åy—¡ ^÷f†Ò8ÔµÖ‰x”´Ú8æcêHm¸ÔˆËcý!—1ØN›HNÎkb—àæÍ!Î«lªqV‰Si³„WhµÕÒOzù„:OŽ'
’œ÷F£lÊP—£„0¦U:k^&ÒµKm>åe¼nhÓZ÷p/Ô¨ƒ™¸³#¤Ï“åB3@y%MôJJ#™Æ»ä!U®Æ8%´Ùó&{zšº:f'„T	JÆõÆÐ0ÓJ+Î§§«3lÌ„i9M_™µ9vÎÅ³¤:kžŸ‹íT£šU«Üu‹i!—&–ré³½?dÀ÷=réö~Ó+º-2¹ñöyK‘ùÖ™2ð¿¼çÈ¢uÙ0GŠýÒÀÞ;nÂ÷†|ZseÍðXÑÞö¾‡|×ÐU}‘dy7Í›b¯¡Ìå½ïýÆ;È¾þúkü·¿þ]¤ùsÈoZišÊ@ÖÇæÞö¾‹|›Xîì|Œü0÷0NxU‘ì=¤ûìÝr7éÆ]©Å8ýùQ7àÑjVíê  Þ ŠöˆC2ý|ü«YÞäs4¶n‰€C÷Îÿà‡‹äEäGÎä°’4’C6ö¨½÷‘ßÖíÐ˜|ÅÃ³1Q¼d0
[«‹<Ê¨¼ƒ<±ÿ‹à>°Áþ¼À¼ŠÍøz»:nØÿÃèDÐÿƒdD´ÿ·ø ÍèÃÙHéöL´˜.ƒ¯Ñ0†²ªŠÖa˜ÚñBŠ!  ãìé‹’"š,¿(J²f*E½DÙ!/öäDé B>x`°êGQç<‚óõÍ*Žl;½×T C;ø*È¨¬‰º$Kh$†gG@1”EØ|É*Š7Ð!?â2$I0…u¤ÉÁö®¬ ]…Õ>t¿œ/­Ã7¨»‘éÐØ¼½Íþrq Õ	é;ïú‹_¼D?vb²r‡«¦áKPuyM™[cc¼\9Lûb‘$\Äz¶YýYV7[W‹¼¡ÆE­]Ü×m‡Å¼iÄËzÉ<. !Cã‰Ýxx@CßR7dKøyéoÇÇ›=ëÌ“}±$w€zJä×=yU¬¥i* Ý´§ˆ=tª¨ªUÀû‘leÁj€7>PEó »³€boÕÃl3 *–œâ}ã5HŒèØ€§Ø`Ó+‰ÝÀŠMÔèécUBá¥u#Ø©±Ö±]žb­~il—06] ÓÀuÎ£¦Êƒ÷þÀŽ:¨ad×­ØoÏùÏC–Ä¨ƒ?ÞæÂz'Àsx"Öè¯·žòôŽksÝXW1A±ËÓ˜òòz“Ež
 R/QOã<¥³tY—ŠÁRá(.;ú¾HZÌ.Š ‰¼E€Ï¬2r/G³HÓÌ È£Ùsº€ò@[TâÃEavQ/Qq4šú;Q\_´|‰q´Coƒ¬[ÀôN.1gÖ¬Yk‹%€²áñHÑDeÈ«/Ñ:¼î§Ì•Ó\YNªCqvm:!}Ùx"­mä†ÊÁQÝÄc=,ëöãn%ÒÄž>:ùöo”oà]NVÁ¨­Xý ð®ùeI°yâH78ƒhüP†(¼Âh¬9ôŠnÊÏA`F'¼:–áÔÂcÏ²\‘Á™pÇáµÞÜ@cYPhçâ(_i/Ð¼’Êê{€áÞ¯¡Þ Çá2Íbµ² 7ók¤,ÁÈ0à7ï¬|ïk`è­ÂüfQZ»2À ñ•<×›á6¶¤´ äÖï0
'…Æ…— çò¢
œ¸Jí™…j‚éäc'¼¢Â‹¦Pxà'@¤Ü‡v‰}À¹$t¿ÏwúÎ[]Nv0‰]÷Bå^®„è:ÅÛm®eÅ@3†Ý^~ !÷DÃvNy@rŒ6 ÖÞ"`¡<*À¼V9^[ÈK”0ü¥CC
”³¬óýöÄÛÇ´aÐd¾:l•f­¬	^n•áã(üZ¶ó‚¢AƒíÆø+e0„U ŠÊ#x?XgÞÖ[Ä¿rJs
Ã1om¬ Æyx;¬6=3Á Ûcå†¯Ö+ÀT(¯ªúô
Œ—BZ/^Ý’–M\6,¶$qN f§âT-§½­;¶¤¯()Ð¼á"âÁÛ‡²n0øFð0N›Œ»µzJõ;5B©,V,Oy¾B|Í¶³-ÇcÑÙå€P89#r×ÉKOÍé‘Þ‡ì4XU¯­4¨`GXnq Ó³XÒ Á2<UªMî%Ú2d´xüÒºõ@ÓM¿lâÖ Ó8ÁÄ0ðþ2…¥ˆ%¥ðpMW4r›¨¹Ë˜ %°‰¦ä(”¦y¢fBƒ,gÌm»$uWfÐdsªúÝðKÊNlÀÃÇ¶Ã
xãÜ;ðjˆèÏÃ4Â75ÙÞ¾ÞrÂ·eÿ¹»ý¬æ;
½ûù¯D":ÿµˆÅcñ_–t­[R´ëOql®ý×ëÀ_g¨'^\Àpœ!˜'héµÇîütÝ¼.Ý´'Ë·´wÿ*Á†ëÇIž0™¡…&2É–ì$SrG$…¤˜"‰„Ö3”xLL˜ÈãI†O	8Ãó)ž$)æÅp¤L»ïliþo8ÿ™ i?ýOà$Eû?Û ·Íq½xÂ69ôˆ;³B¿”‹ùÛåØëN¤óØ”‡®8µZÃŠÓR)}¤+ñ”Òèï#çUökà§r%ßVÕ‰šËÊâ¼~TÓˆq¯ÎB÷úh’1j­J}Xnõç9>ÃÌOÈAFÕ¹û}„<é·fµ:5£rªLµN
D^éfzm­¥ëãf•	^dãÙÖxVÊšPÚÓåž^Î|é(±Ú±ÇõÝÝàÿä*ÿ§#þ¿x4þ?»ë<ÙþO„ðŠ‰øÿ6ÀËÿ[éR1ãeÿ·8VË3Ó—Ë¶øfî°|ÕîŽã.v‡üñ ñ}D¯æÎså>'‹ãúùéø$WOõtÕO†øÑQ©?75s ±ÇS¼d(Ó+,UjÝf‘Ï²ÝO?õ2ð`Ë{Ô¾9°áú‡[uÖ¦ßmê¸aý«ö
ÇÈhýo¾r^Ø_Ìèþóý1„Ïì;ÛÊ d¤[3kcU}¾Ïw:ŠªØ¯½Ü±29U…Ûeà‡ÝùÕ¾¡tá…Í¶Ï|"zÿ¾2¨BY”öÕ¾( 3š_x¹Í)‚ÏµûžA%ÜóÁçÚ}O¡®Ý÷úçÚ}Ï¡®Ý÷ :É{žD½¸çQôÏµûžEÿ\»ïaôÏµûžFÿ\;Žþ¹¶ö¸ÀçÚþë×¯7 ÿ^’[Ñ˜»Ûÿ)Ç"ûÿ6àžóêÊ¬ãÎóŸÀ	‚ˆæð&æßëOë¸ûü'ÈD4ÿ[7=ÿ"ß`þIö·»`ÿ%H&Úÿ}$ØÂú§xZ$E™N&q,ÑI†“ŒHƒ_#ËA xœOòIÄˆIIœ"x§@žL%^o
1#ØÊüßDÿ4¤ÿ8Ù·×ìÿÞyû7W Ã<.—s_¸:n"W)îLV®Èº1Â²ÓªÈ±µ+:#g÷wým3ð²dÓÛfÖïýF¦c?ìÿÇ™Ä*ÿ§"þ¿Øýyï‰†ÐNÊ;rÿõÛÛ˜ÿöp’&Vø?MEü]Û]Û]Ûw—kû{Å>,¼iú?0†ñìD"zÿ{+°ò?­Êÿx$ÿo¶±þyèVÅþ‡xL0‚…ˆþGôÿ±é?+ôö¶[¦ÿ–‡á/#sÐÎÀ¶èÿµöleÿ‡ ¢ýŸ­@t}tý[}ýc/ÀG†]ÿp*äþ‡hÿo+°þ/ò‘ò¿«éÿo·ü·ôŸÀBÎÿcýßl“þGŽ »;¡ÿ¯ú	:Òÿ·‘ÿGäÿù¼½þ» ÿEûÿÛàÿ¦jD&€…Hÿ»å¿] ÿÑþÿãÁ–é¿õ3²ìì„þÏ„èÿÑþÿV zm;zm;zm{“×¶{å>ì‚ü‡S«ò¼ÿ)’ÿÞ<¼iþï$ˆ4ÿ…mÌÿúÞÿéÿov‚þ3ô
ýODûÿ[­ÑÿÇ-#žðøÑÿˆþ?6ý'°ûoôþËVàQé?4>ö ¼åÑÿˆþ?:ýÇCÎDöŸ­À£ÓÿèrˆG…ˆþGôÿÑétÿ÷£Á.ÑÿèrˆíÃ¶èÿïH`Däÿ±ˆîˆîˆîx{a'ä¿Èÿ÷ÑàÑå¿èdÈ£B¤ÿ¿ÝòßNÐÎÿ=ìýŽ…<
ì„þ¿zÿCÇ#ýÝÿÝÿÝÿÝÿð¸úÈûo‘ÿïVàÑå¿¾<3L}$G€GHÿ»å¿] ÿ	|õüAFô°;ôŸL‘ŒÈ'˜N‡æE>•äe)	D‡ÂšpŠè–LÉ.v0žÁ:J”†–SI†h:z&|Øúòþw¤ÿo	òýï&sÎ4RK
¥³ó!3GNòØ¼‰Wxüâ¤Þ0NÏëÕÃN?'Ÿ™©çýïæì`¦Ÿñ£I÷@Žxn4íV†óøhÜí«*’ïSÅioØMð|e2‘éyR!.æ­ãCS¹Êss©]ˆŸOO¹NgÄÒúááì»¨™§Ñûß·…]àÿrÿsdÿß
<:ÿ7”näþýx°ü?Òÿv‚þSÑý¯;DÿCRDÛÀovbÿ7òÿ~4¸iÿ7›…þßÕåþïáe[?*ôL¶©hùäÉa¥Û,Ÿ¶¾Qû¿¹îƒïÿN§ù®{=ae"êª88™¹nê×ù€#ÎÇÂ<91.s©ÉlDkG<Ñ;J³¼§ þž×‡ÕF¹ÈŸUˆÁ…À$²GŠæDOâÙ™pfÔ{åÄI/Nˆ¹«B‚žV/3ñ"UÄJ'ôzp:ßÇNà×ù€×§ì´Î»í#õ —â†l/²“¬y!õä<­"Ò%sb½œ‘šh•	–j™bš2RƒJ¾Ñ:,˜2®Pì„/_ˆñÞÔ d¦„Î)^«L…žöÖlçÞvBþ‹Î?<ºü=ð¨éÿo·ü·ô?:ÿýh°Kô?z`û°úÿêýÿ	<Òÿ·ÑýÿÑýÿÑýÿÑýÿÑýŸ‘ü·uù|‘Òÿ¸éÿo·ü·ô_ÝÿÇ©ˆþoþ_];ò¼Aˆôÿ·›þGú¤ÿGú¤ÿGþÿ‘ü÷(òŸ]k$>ì‚üGQ‰Hþ{$¸IþkCù¯›YÊ¥ž8¤ÛÚä¸'°‹¶ÙºÄ´—¾_yùÏñ}Hùo3PÄ½ØëzÐïc^åhó’çk…v¦F¥1SÇ¼ ö{9ù$UÁø”Búñ„xqždÌM7NGÍÞ Q=<Hµ:sŠ/‰CãP(àÉóƒÊe5­^dÒý¹_ÌC œ—æÙi¡æÈyi«¯Å£éY:]kØ)<jäÙZ+—ž–3AQ$ÌaTÆ3h¼Û:&“yÍl	‡I®˜âWXµ£'Lã”¥©ü8›Æ¦È¡¹žÎ€VèÅ&@šþùé¡**”_>+qKy	\”&p3-p}^¯äÊ0/f˜“ü\ëiô!Ñbgj÷|Vé4;ú´Ø­NJ%„ÌPb³oˆ)³Ô£'x{Â‡=á¨pÞ­I­3²Ž'ÎRØ¯œÀÉ‘ü·ò__~ëXïNÀ.ìÿD÷?<<äýÃöXm÷.rÂqþ0—0$ï“|û"]Ñ•’™«µ³ø0=UÌÚ¥{ÿÝÈÌ¨ËVó’‡Yò¨4ÖH5ž™â¥£6…ÍYƒ;¡N±Ä	#ˆf\šU´ù8Qe³šDRcðzüXÕál0UÎé•FÑý·…]àÿx˜ÿoäÿ±xÓôßòéœ<v¶1ÿ7ñ,ÄÿÞÿù¼yØúOP«þD"¢ÿÛ€íÐF€·øá	^`:Iœ$øT'!â<&i1ÕÁH#èNGdÈDªÃ')“…ÎË˜ˆKÑÝ~o
vþ‡ééÛ€‡Ôÿ²t·ÃÎÍqñXTC¸sitv"_òcùðJ ©bG"zçiÙÑÿVÝ¼Þ
È&î
Ð[!Òÿn;Áÿ±Õ÷"ÿÏíÀvøt²sWa[üÿ®þŸÐþñÿ7‘ÿgäÿùFþŸ‘ý?’ÿÞÿ°ÈÇîeë`ó¿‰ý?GöÿmÀNÐ&äýßÈþ¿Øýg¥¢ýÒþØýŽÀ†ˆþGôÿñéÈý¯Ñý[Ç¢ÿðê¿Çî{ýèÿãÓÿèþ—ÇƒÇ¤ÿ<®þ~TˆèDÿþ“!þŸÑû[¡ÿ+	"‘íÀ¶èÿ]ßÿ‚úäÿñæá&ÿÌ|ÿkqÿCíì0^,¶µò¸Tâ’¥ªÑ÷êóÀÎüEzX®S$c;Kä¹éáIkÎ5Ë "èãI—jDÎàÛçq@Ïš\»œ®Ù¾"WåJ‹È‹Üù9kSüiåB˜s­rºhgî•KÐ1Âãq•›³'¶§F¹™Tzî¥
ÈÂA$Mžf›\¢œ=›U.¸Y%ÛŸUT„í°ì"lzrÁ•\ÏdS××s®+ùöÌi^™kåúB[×ò7¿ý#Þ{æ‡‰ù…dJ;wlNº¼z\:&ÎòFs\99ÏÖ4­!WJñƒ~[©µ†r{žëgI$]/Éæù´>8OáÍ_ÖŠÇ¬–T2ýøy…¥g—ëßþ‚W9 ÷yû>ý…\÷öWX¯{l™‰§Éc9~"ÚýfKr‡frˆ¤âtÀ_ž—¹ÂU½Þd¶›m’É|!ßég
J‘cØŽ¨Í¦&×Hõðþ!†cD3S£ôäá¼öé7ßccØ	ù±ÿF÷?lSþ‹Þýz|ˆôÿ·[þÛ	úŸ¹ÿ'òÿØ
ìýŽ†<ì„þO¯žÿHDç?¶7éÿ¥9<ÿÁ/ÏÍä¤Ú4”ôqº=«pLý”–:â7êýï|ÿÁßÿ¾öìÇi9ÝrÏ~TÝs®y¹Ý¹ZB1…ZzŽç
Ì˜ÎÐ‡Ùá±œ»¨!)ú˜lOŽ¤Ô ¯TXQ8+(ìø\9ê‰4›²hóSóêœdd§=?ä»Jqxx} ›žûp} !ç>x›”4ï*l«“?Èœ0ŒÉçõK¶Ø½šeÏr½×f‹gý9{„„Ÿû`•SyÖ?>Íx³×Np¬)Ÿ2dÿ´šÉ\v1Jˆ×ŒA¿5‘#PjY¨ªCÌ¨e;x¼—Öä©Êç­Ô.^’q±XVñÑ¬ÈôúoÁ`'ä?ŒŽö	SþëË3ÃÔGrd x<ˆôÿ·[þÛú/ûÒ<òÿÝ
ìýiÇeLH2Å‹)’`hIè¤™;¼ÔI$)Yf’2.’´Øé)ÄP¤Œ¥0&Ac4]µ1ìý»ÿ)Òÿ·yÿMÏ2=¯%°¬0kfÎQ®BóTuxD0)>K(é£áI×œ`ÕrÆ½ÿ·¬uª‚˜žµˆƒôe+iÄÏ»üU•ÄOúH%#K‡$6‰Óuþ0ÝP)¡Ü®wsœIãZ:®%Nµáåí&3Yñ¨ÚLõ±ìðP‰îº-ìÿ'°óÿ‘ý+ð˜üßPº‘û÷#Ã.ðÿHÿ{<Ø	úO†œÿü¶»Aÿ#÷ïÇ‚Øÿü¿"ÿïÈÿ;òÿ~{a'ä¿èü÷£ÁcÊÖ­Ð‘àQ!Òÿßnùo'ètþûÑ`Gèô@À#ÁNèÿ!÷ÿ'"ý+ÝÿÝÿÝÿÝÿÝÿÉÛ”ÿ€À)ý; ‘þÿvË»@ÿ	,ù?<&ý¿8ºvÐ#xÓéÿo7ýôÿHÿôÿHÿüÿ#ùoÛòŸ]a$>&ì„üGÑ+ò‰Gòß6àÆû,ù¯º”ÿª•®9Ê®Î×;'JžK7˜î7NþË=¸ü·lb6KŸçñ¡ÐOäÀôyð°%â=mÉbE6]Öëí…aTµqnÎÆ½BCoóÂ‰T´Ó&™&®Ú§iûà’1°Ž„Ìôa
ˆd:w:8>Âø:qYVyi˜àkü8›4Ž®FÇwt!dÓ—e–´¥3ÛÝNeÑ³¬dÉrgOSw”îr¹tMÌZnªÓ³tºÖ*ÀyÏ²–,Ø´H‹S ô;s™;Ì²J÷–2ŸWäC<2_È|9VáXœÏ+ÊåHÃñZ^Ì•'ÁSÕÔ¨'_Ù3vZºJKWgI“Ë Å\rv`ÓúÅÔ”F9Ù"ãÕRÈ¯hzZó_-\ñl½ò—ù¼É‘ü÷Èò__~ë¸îîÀ.ìÿD÷?<<äýi¾[&òã\ý˜hÇOÓ2eŽ¦)Qµ§•nW=«f˜±™»wÏîýGÜI¿*UªÍþ@Gz»Ìøis@áñ1‡q2QÉÜärÌT
	1~yÔiI‡|:G]ÌÌ|_º¼8lk¼Dôó£n¼”1øùA=Ýÿp[¸çúÊÁÅRÇÝ÷1
ODû¿Û€Ÿ}ÔÅ½Ž¼ñMæ?A1D4ÿÛ€]ÿq2äþÏèü×VàÍ¯‘½v¶1ÿw§ÿ$ÆÐýßìý'¨û_¢ó_[­Ð<Å4Å‚€‘IŒ‘x	‡w{b|Šçyš&S2ƒ%é¤œà	#p†O„”LÉ$#ã<ÍËÑýžovþ‡Øp,Ù¶iÿ9¯
ãþ¼8lQgƒÞy“@(E NNØÌU¶2%{•ËrNWÊ¤^£dÇþÓ¨g…Óa—;ž5sò¢¬kÅü96¾,$'Ó:¢éêPLG§UŒàzµê =;¡1¶Eªés®C×Ç…r«E¤JíQ&Ežçš£*–ä"ûÏma'ø?¶zþ§#þ¿Ø
ÿùX08:ß½°-þÿ4ö®ð,âÿÛ€›üjðþ7y°¸ÿ-{(T{ÉdëÀTS™2.ZÓtvåþ·ùƒßÿv^N‹îýo5!q¨•7¾<NÔb9­»NÔMè@„'¼½R.”mâ„x³ý€úÓÜÔñ¿Jƒþ‹WîuuKw¦é4oûŠgîÊòe
O¸æÒ8ïqH¿FàôY:›ì÷ƒâüèp–H¥Ë^¼7¸sÊœ6/Ï†Æ>7+½b+;TU6Ù\õ°Ö®úÒ›çr•I¿œNä|½Eƒ„T¯tÊ9,äÒ¸ü Ì&-'¢C0>eö,¤sðƒuÅç Ö”…^Fsvh;•“\±[ëæyS½d®[ LnÜd/ùËr~HM{:IOjÅS}V:ÓúÞð’\¹L®Š¬³Ånf6ºˆ«­3}ÆsÝ²‰\¥’*5?PJ-ztÐ’C³gó£Ò¸›)æOU±EÑü¤Ýh™u6¯%ÙÉP ›Õ+³?:*å&‡Ô:åä‰ÑˆÓœƒvAþÃÉÿŸHþÛ
¼yþoúyì^F°¶1ÿØÿñD´ÿ»Ø	úO‡Üÿùn¶CÿyèÿÝô¹ƒÑÿˆþ?6ý'ˆèýÇÇ‚­Óû(@dÞØý¿öü'±rþîÿØÜdÿÍCû¯˜Yžÿ¬Œ«ÚIå`&ÅÓù™~Ê(:×Wk+ç?ÅùCŸÿÌ7ÙS÷ü'—OÍÎçöÞw@
Y–wßáˆJ)BN=±RnŠÓÊE‘(7‹XµY$Ú0ìÂ
ÃÜ0¤}‘ -{SS6âÚ²=¦ìN9Ùfêé´]k×M¾M±á–êô9rÝî»u4?N]¥kx¾Õh–OôÒ„©œ*gGíÊ¤³=¤]o¦Z©ß>aÔz«sÆ±G9^j(
UfÎ™óá4›¬4˜¢Q–Žëô9ÉÍòÝéÑE³™.Áó Hà@h¡›eËîÝðjö‚eËÃ²ù§µ~9sÄÓƒÑ9?fÒÅt
ÕKýéÑàr8hÈb‘¯VGX&G—â*<?.³ú¢[Ö¥"X—-s­L±–!£d¸î¥Ð<“É$?OQíT¼§0Ù"%7´vkz’šd¤x·ØmPG´>¨Î$=§sCž+NË)fÜ@NOÊ…cSf2ÅL¤J«Î~óïö¸ì‚ü‡S!ößHþÛ
lGþ‹žùØUˆôÿ·[þÛúOà«÷XDÿ·Û¥ÿ‘#Ø®Á.èÿaþ_	2Òÿ·‘ÿWäÿùEþ_Ñþ$ÿ½9ù/zésW!Òÿßnùoè´ÿÿx°uúo¿ôYvvBÿ'Bô*Òÿ·7éÿ,Ôÿú?79mâõTúbŽÓ•Ê9¦Ö3ÚlUÿ'Eÿ_n¬_•Ûðîc@¬Ë gÛ ïeÐw³$§Pbßi}îÞi}g; âN{ù1=Ö°zž9'®ÒDéà¯$L…9o7[âÅLäŠzª] ú’ Q>=d•KSÚEšÌµxò¼>U¥Ôñé'ôáTç;T¾Ù€¸†€»Ø˜sídØ‰ñHªÅU&óÓ*a¨d¡Ê³ó).2R‘ž&zµË•×gv€[˜©*ŽŒ¹\Š–ñIu©iÕH·²ÓœvÖî¦”•0“8ÕÏÙÓÃN²jåÿoïJ·W’ôüÖSäPwº«ÚHìø¶ûŒ«ÙWÛôéñhI„Œ°¶:5Ï>™’ÀË6Ueƒºœß=×Rî‘”'1X(5«%Õö›†Ø¢$z”çG“Ñˆ›Î3©iáwÙ‚þÇøÅÿaˆþw¼ÿú“³?¨8ÆüÿŒýí?bÿ¿?‚ ÿc;Ÿ·ö‚ÈÿcàXòÿ¥Ÿ˜ýdY85ˆü'òÿôò?Aü¿N„ËâÄ òŸÈÿ“ËÆçþÑÿ‚ Èâ„ òŸÈÿ“Ëÿ¤Ïï¿ÿ£ XòŸ‡86Ž%ÿ4þCŒÜÿ8
HüÿÄø·váø%Bÿc|ö‰ÿÇQ ýÜ9!ˆýÿ±õ¿@ÈÿäSÿ"ÿƒ Ér-ä‚ýïÿó?±ÿß$þ‰ÿ@â?ø§µÿ“ä÷ŸO„ è¸2-Ý€dà öÿÇÖÿ‚ ÿã1Ÿûäüÿ(’ü—F“GIFé#%3I!‘IÒÉlV€4L!-ŠQŒ§â|*-Æâ‚HÇÅ”˜Œgãé[ó½(ø÷Eä<ÅóÿaÇþou*dÌ€jáfcÿ—Ê¬\`_:Î•è÷ÚmÙ\×†Õ»¥’Ó[Ñb´‘¢LÝÌÌuv9›²Ù³ø|Q¾+Ö¯ïe¡Ä;lƒcÙv&#uµy¢3ž…±=H³…jÅÍl†›•¨›qmhL®—­ö\ÔôñT‹s‚i¤ó²)”|¾_kÑ­Ô%a•“rÉ²µÎ²ÂKå+íI§N=àCÖÿããÿGâÿXÿME&îß§BÖbÿÿIŸý?òûßGA ä¿"rüŽÂù/ñÿ>^õÿîq+<Äÿë-c½ùâÆbG©XµÚV•Vª¯÷~ãóß¢ùÖç¿n\?/¬ßbx5XÕ¹çw©×Îw[­r–>+Ü±eEPáÕ¨Ã©uù^°Ú÷i¥KÅød1Ó£kñËTe8Ë.¦éêÙ"Q«ä*ò‚áÖÙ|F»/_¥F‰æMÎf´Ø-iT£Q/˜Îñ.õø|²uváœï\Ÿp®Î²‹ª{´{—ãÚ‹ŠÎ>:Æ¥6ç¸‡ãvQveÌVJ¬¼ŽQÕx6Ó›ß]NR1æu¨ÝŒ'õ›´‘kÄsh©B—è.«°ÍÞ2žZØ«l4‘Ë2hÆ¸avpVYPSSªd¹Õ0™ÕõÁ´qÓ¾ þßÐÿÈýï“! úùq€‚Øÿ[ÿ„ü'÷¿O†`Éòã ÇFì¿øÿØÿØÿïÿŸÄÿ'ñÿIüÿ“è'ÐÿÂGŒþS‚Øÿ[ÿ„ügžþþ+ñÿ> ÿ‘Å//Ž=Á»Øÿ[þûŸØÿÄþ'ö?ñÿ'úß‰ô?·^¢žÐÿÒé§¿ÿ'úß1ðšþ7\#ýON=ÄÿmÉ	«Ä±<´§×éÚ2Ï”ÂòæIü_éî$ñ×¬´‰ÿ[Ô:&…´­ñ¯Ä ¦œ‡¿˜ÚÕg}c #UU,TñŽõÕT)øÕÀl{>Ò~•žÕ,=^]ëZlBO†Æˆj£¹êå¢R+jwÝn¾SâÖbìLntµtõš-Hgédã’ò·\d‡H{kwÙ†¥Mïä¡¸ äaÛG¿»’½.à8?N9¸Ý/æõ²Œœ\(æòI±wnÆx¶•ål”æƒ\^È0kË¸„¹õ”’+™Lãºï6ÍF¢_5ëœìz ¶ÛãzîŒ+j9ux]YøOuŒ£r×n‚§‘†E¶^hs•Â JW{VŒf$ûr-æÎnnªåœ¢ÜŒò•šFé©Ñýý 13ïš5VÉÝÁlvõfoÅÅS¬jMõz9qeÝ×¯2y™k0Ñ«Õ¤wY½±Áv4%úÑÿ‚¡ÿMà‡[|€ œÿø§Ã[Æ°íBÏ®ÎæÚ•œ–»”=ìŒRì,›êOjFAÔî†Ã;1Ù…¦noâ?jñT³0àäVTIó•™ºÌÎ—%>¾ŽŽ©Ñ¢«ˆ·&è‰Lwd3Þ˜ëùþ {¶R¹òÈ>ëu¯¦‹ÔÂ[WíKWÑž0L’ø‡"ë?“dHüçáýå¿ãÓKœ<ŠcÌÿkë?íãÿÿc ò?–ôñÿKùKþC)Ë#)0‚t†¥3Ã’	†–„Q<)B‰³é#ÂT†ÎŒâb<™ŽéD
´™DŒIl¿÷Aä¿ŸýOûïxKûo1:»V4KÑtµµË÷ÔÙ 7º–ëC‹©ÈQ»oÝ˜°µÌ¼gÿu`1ZÞ§F‚`NÓ£BùfžÔúq«YêjtV­êU¦¯Ü17#¾ÃXq~}³'\Õè^ÞÜò cŒÕ27ˆÓY8¿æÏ¢jžØ‡"ë?ãÿ—¬ÿGÁ±Ör³3˜8Öúÿ£þŸñ$YÿâÿIü?‰ÿ'ñÿ$ûÿDÿ{Ÿõß6q¡§î'?Ž1ÿ?³ÿŸ ûÿGAäŒö±ÿIü¿£àXòŸ•¦ŠößO^žºûDþùzùOâ¿œ
'–ÿ8þß©‡àCƒÈ"ÿO.ÿIüï“! òŸÇ¯HüïÓ€È"ÿO.ÿIüï“!Xòß?ñy?Kþÿèï%ˆÿçQðêïÝq+rñvS4ÎVR4WZé×iE/LÔö“øâú$ñò,¿‰ÿPˆ5ÆÔ¯Ä~ÀÏ¨_‰ý€]Y¨c?,Wí«ŽÅ_%Y/•Üz5öCÉÎT—¹6Sš,»½ú@¯ÍÓkå¦zu—´Rù1uÕé]æÊZmr5H«þè†¯²Õ"/u%YOÓÃÙ"ŸitÓ³.µ:©a¢°*É‹ê]¯—«ÕÙD‰Â>y÷·¾ðÜ–åüárScÈÛé\%—¥ŒNm²¨NïgÓ.+|³iÐ\1UWb—Ér‚çí§Qd¶^ès•6—0«íÅä{¡w~M^e£cmx–ÎW’°«]õƒìœ“¢rEî&«)}Ú¸\IzQ/ÌøBeQÏ¦í.u=¨—[<­¬¸D6=—ýè°GC ô?Ægÿ—øÐÿÈÄþÿØú_ äò©ÿ‘ÿÇA€ä?¹rÁþO2Oï$HüŸ£à5û¿í8ÝÞÿÈ_
Íq&Ó?³ÔËl&Í»þ"÷ôþÇïóûßåú[ÿþ÷!w?‹’ìþF8UXþÜ½ÍµjÒŽ1©›\>3™˜g•uõr•›Jµûq´5Ã¤µèÝßÌÌ*³¶ãJ??SMZl±yÙ¾ê”Ï&5^‹y—¹_Ìa©ÓO¡„É1ÿú½ÍµêGî}ìþpøæwÃ©C8|sïƒ[wQµgånø‚\·¨e6£&×gJ­Ÿ2ÎäY‚3%1³®Öl™«”®U±ŸLñó«nßê°%-ÃÎgBª×\Z£Z™Á^jê™Ùþn›Ðÿ˜äSý/Fô¿c  úß®LK7 Ù 8ˆýÿ±õ¿ ÈÿxÌçþ9ÿ?
‚$ÿ&ÁóÓ)aD‹éLœÎŒ2Y8BFÌ&bqˆ„D*#ñ´OÐ"ÏdÒ|V`Ò<Ÿå‰dšÄˆúqAþûÅ"çÿÇÁ[Æ¢éÊ¢VËUu%šU&BŠ6ÙÝe®a£t¥ªsµ˜‡âºSmk±MüßŽ1çÌv¿Ñ™Õû“u‘çÒgëAbÊ©ú™ e*1˜ôWíNr•,ª0Ù”c%EæÆWZ_×í^3c¼ÈFó}{UË—{4œÂ\}¬×9ÿéPaý'ñÿO‡ ¬ÿ¦"÷ïS!ë?±ÿN‡@Èÿ¤Ïþ_ŠÈÿc PòŸ¸A8ÿ%þß§ñÿ&þßÄÿû·8Êý)Bÿ#÷¿O† èNhh²pûÿcëÿäþ÷É,ùO~%àØ‚ýïÿ?Aâÿ$þ?‰ÿOâÿ“øÿ$þ'ÑÿN ÿ!…ý§±ÿ?¶þùÏÄˆÿ÷‰ ù,~Ñxqì	ÞÄþÿØòŸØÿÄþ'ö?±ÿ‰ÿ?ÑÿN¤ÿ¹õð$„þGÇ|í¢ÿ½?^ÓÿšNüŸÒVÿË]êƒ8wÅ)­{Ý6ïæ™œÜ^ÿæú_Ñ|kýÏÕí°j—ÏsÃ3&þz uHŒŸø¬Ö7&³ž=ËÏ'ÙûT¢[¾™	2]f””î¯”JÙ”ÄN·:gJ5ù*EwÌÄUUìÈÕ»Ô»^[ÙûQÜl4VJMNÍëD§Ùãf½¤/¨§ºÝ•ì4ŽñãL‡ý?ÛýbnQÏ!Z0rr¡˜C­cïØ:õª³h3Æ³å¨,·`£4äòB†Y[Æ%Ì­§r%“¡×Íx·i6ýªùÔYTdë…6W)§—Bÿ>›¯W1F¸¾âJFªX|t> ¦ËÚr8êÚvö¬T›«¬’«t®¥8£ek¼^a$y¢ZgR–éò¬|<ƒö}|i³dú¾}ñûúŠýèÁÐÿ&ðÃ-¾@ÎHü‡Óá-ã?´Äx=¹<³š½EñL«Î(ë¬6‚\ù®%­;%”³È´–ÖŠ4Þ‹ÿÐƒ«kwÕÆ:šhžõb†1®HŠjçÛ£ë1M5ì_‘á’Y+÷ÑþŒNi=¾™-Kì}ë¾žo5ã±Y.èxµbçïµ»Ö¸lø‡â×ø?²â§¯/Š¯Ø©tbÏþ‹%Ó4Ùÿ?
>NŸ­E[ ’«£oÆ,XUüÌèÐ…¡>QŸ@·•¿×j&W$¨YÊHÆ9`g¼8†áX„FéPÂðÛ•j4œ¥Æ0ÈÃ‘¢)xÁúè»˜ò/+šŒ;y€¦KÐ|ã&í´çœàmÇåy¼CÙaÐà§ð|§ òú”W´s°³n;Ïßºn\b¨;ƒ¢3‹]AËU L @U_€‘n ,jThA€¦Í‘AhZß©5NSÎx`ÊºiiÎàx´óö„¼éïÁTŒ5¬w!áMKÞ‹~eæ]‰×)þr÷ÕÎ÷&ßw+¿¯¡ÖO‘`ÖX1	E‡@,@TˆCÄ§3U±È.	ýš@ÑÀJ·¯<w¡¶‡®" ÔQàØd`¡ 1¿àqU:~zoÁ¯.7º%xå8Ý¨E¼xÃàW¸BüµË2h¢²hxx¶Âu›
nJj-t€–
UòøíÓÇð¹ïmÅ€ÒÐ;Ü¿8ÂI¾“GŒ»/9“Ù)‡Cc¦k.m|n:"ƒW¿8mÁ”›Íòº‡ˆåau¤óŠ±èÙø8/×@ýË­ð€ó¶j}ugGy\ðù£{¡oß"›ÎÿAß\Jþþ=ôb!‹±‚ÆX,”ÕÆvÎ«6êàÈÐ§NcpŸ·E£Ù’ž)	±WçW`@s†	mÕUäÝH{GÚîÏþH×Ñ3eêNŠº!ôäÉE ÐNWvg¥¥qêänj”p3¹æ¶ª°À›ˆ¨Ší|ñ–x¥ñm’ÀÏ<_¿ŸpÙpàûÉ¤ÚéÓYhVz$@ÌSÝ€ž(±Æ<"ôU4 j•„†ìÞÆJ¯ª+¯@‡ðø-Džr‰ªëôW™@ÂËÙI!7§Ûšf6dw£Ûhñ[=ð%n¥fO´¢:+!øìdúòÕy‰x/•Š&Á%øÜÅß¿xÅyÝÜ²¾gÕŠE“eØ¢å–YåófŽ¿D±`CGœ½•˜£<aˆFÓ-0µ-*¢j›ˆ‹¬ØôÃ`Ý{åy"ÝtJÂµó²l@—íöÎ‘ËÂÃ ã¹BÚãÑŠ¸Þ…²-Ïi¼¨«ªbâbß‰rzdp§í0ÞWÄÝxØÏArûàetkh–ß¿£<Mß¿£™¼;õñ:÷~¼äAï…âµð¢ˆß™à­Æ¼$9v‹	ÏÙ}§9ÝÝ› WŒè¶ÿ%]œ@#ì}¬~ÝþO¦÷ýÿbÉTš!öÿ1€g‘æ9økì¯…I ÷ù\ÄuIK™ò2bêñjJ2"
dDþü¶Ã•‘4§#®d€Ú\1t+´vV‘Íu*Ü-ÇÞ–›õÂEZbÔ·8&}2vA¡ƒ?5XT„Oc©O/åÂÇxÅJí€Ê7[ÝÏÞJ~¹¢jáæÇêác1‰Å“)!ÆóB2A>‡ñä(•‰"1RzÄð|Lˆ£ÿ³1I	£lŠO$2¥ø[sB96ÓkÇ¸¥édâÿq"63Ð
tÌ1‹à¯ûíq×U$£°6êêHAÆÇÁ½xé·[æ®~¬H&Ë©$/ÈÐi‰—˜Lˆ4Ÿåy>•JdašÎ¤20ÎŽ)ÃÇÑHf²0‘†Ÿâ!€ósãçÎßÙ„¥¿:£1×U{
w†+òã'"=?´7ÞhX‡Æ­»NúQ1JèmF<åÄýü>	_áX/ÇalÛìäDÕ¥B£Ðak·µf©Vjlùùd•n¯Ð`óùN¡Û½ #ÎÏ¦Æÿv+Ýz¡Wnæ/0…¼–ÔŸ½Üa¶–Û•+,C™”fDPÑöB§8¶Vï¶*ùo‡}y5u¾ÒyÚÜÀ`üÙ)d¡¤«ÞJŠq¢úÌŠÊúŒ·ÆQÓ£2RêlÁ¡¥§sõ˜iõÝ»=FG,Nc>§ýÛ%í§dº®GÉs€¾ÝóÜa‚]ú÷˜Q:Äð´ÖýBµc>£ŸYyöéÝ?í+$3Fï\³SÀD^ª4J·­B¡³GèÎ{®ÌV\3ÿÒå‰|!×/=N:¨ßùV³Òè]Øš²<F£ØÎŠÎy#jØš§[EÌ]útrâÊoE¾ÐáÇi7ÜöÌh"ê`ž´-ßäª(k¹ÙíqÍF±RºmzWÍNµŽzw±a£Û]¥ýq¥XGfvùæ!zê–Þb{å§<ƒ¼e–‡I(äK(o·Çö
îß<Ûcsl·pÔ\qœÏ½žkö¹r>çõÉû¶ g—„ód6“xSÝîÛn×Qü$ìž8Ft|1âU>ÃÂÌãIB_âøIü9¦ÞÑùcšúu¾?`åÃIÌ¨?±ùsþÞ<ÿd½Î>¦¿Xq^9¥Kp5É¼EZîv8Ÿ[)ñ;$°0ÚP‡ÿjí¥{YÜlŠØ—8{3Žéï}ÄQ>wÛïÔP–…†3ŠÖ0^ÅídŠN!6?oq«ì„û‡í¿±¾°tÁVT)b-óØ~Åþ£Lbßþ#÷¿Ž—åj°zdàM¨°Ç€ŸÃ~
.1ånM"Z± ÿ£u•§6Âžº£ßsåxÚTÉÕÂ@X·­™må°2†Yß_K{±DnÌkT7EqÎv™÷°·Ü-Tt"Š›Ï•<Ø¼öž|H×ƒùß\oÄZîLDÌñ!u¼âÿ£S©}þÅ	ÿŸþ3*(ZTàÍ1vÛ(,ñ‘˜FŠaZ †n|3CÑ,À«êF»1#>;	Ã9ÊR2xÁÙÆmÃÀç–Hs‚¢¥+
[E¡?>QøôÂÙ«ýñ©nåÛn³ßá
ÿ¤ÿõ=¾„À_þf	}¢(c
ÂÆü_4òÀÂ:âQgã|#6¤ù7ßä”Üƒ
% ð9èl…O‰]ûì¼¨wºÓƒ	\xµ‹ŒŒšNPs‘Ìy®TJœáŽ .~ízGA	Uøl&Ü‡“ ¿?à¡kÀëÚ3µ?7”È[àï…füãÀQ{x¹3uúæè!i0¡sr…¾º7†zñÏÂö„lC”V6fâ#•Ÿ!ðÝIú/¯‘G¹½L¸ü}5ÆÙ˜ú
¶ú “	“Ní³1ânb}÷JwÐÝæoK2ðÁ•i!*ôL‹7½Ýfs4k/dˆ‡¶éwu‡ŒpÞ?¾á]Îïþ±bor:ûxYÚ¤@Jm%ß{¶Õæ¹¥L!Z ñ›8M‡¨ï"
Šc„ÊúèvÕÜÐóØëjÎ™0ìæ*:‹˜#Åñ	’•šCr¥ü=qèú/éMÕyÉ¥‡~¯ù?õÿŒ§’)²þ¿ºþcŸPô·þsñ¿¶³Æ‡§ÿK½¨D~^;øZ6jŒs|ÎËNñød5ØGra×<Pîþ˜áÜ‡ì¾’~ï¸ëµÔ"²ê$ƒßÞükuøl6¼<ÿ‡ò¿³‰õ3Ìÿ¯ò?“JÑûüCþ?~ÿóÐBx¤¯(ø“”ç’¿ ('ËžN¹Õ;< »+€ðÈGiêÒ ðr÷ÅØ3–pï<W¬_ùH(d|8Ü…’)šˆÅ•>r‡Þ‹1ÒÏ[Ó°rÆv¾Å4mÇtgC¦Ûc;½Û^¥^hö{Wy×äz§üÃÕ
ÿøæ—ö;eªÎž}‹Zçn°¸“èm™xò.¡øÌiŒ»î¥ß?aÝ÷PÛø,zOÆÃ}ÀùÞÃ&nì¥Ž¬¼gšä™{›zF„wðiÅv£ù…øæ¡ƒæ77,ìwÝÛÃt‰D#‘7×¼—ÿúì'Åÿ«ú_2±¿ÿ§ãDÿ;
 ÿßF%ìŽmËÛN%y—£·G6ž+ëÔ¹ç$l¡®6Â5â¿”üú€'Àöò¡üoAÞÀ£ûöC§÷ýÿâ©4Møÿ ÿ¿+Ûoö´Ì•iA´ò#+Ñü^÷áì	vÓF9(±£P¢öpªÏ]ÊÙLÄªŸ©O?²ãí¦~e¿Û«Èq4±‚§ä8¦0¾Kæ}7¦
øãó£— Kƒ¿ðý\Ðn›áSL é ª×,Ô†üŸñâo—àc7©ãµø_1:ùXþ3)ç÷Ÿˆüàc’í1ËSbpBž“8N‚7“îÓë¹øMªÈ0]WmØZµÏž&`ÉŒj‚ª>Ã~.QgofXžyõ¢…gŽ/CË°¡óÈ€è½‚—|œôøÌJV¬Í¡ÈÎ)“y}Îok+=-]WÍÎOygJ!Þ¶ÆºátÌçÅmŸê^„Ç‰î¿»¯&pµ@&îÃ™Th§âM+ãÎ‘Ð›'¦®ÚŽ¯nÈ¿¼aÆîKPhz}v[è)hãàxå„…xî¤É¶:á0þÇ9ò‰X?WÌ(~€øû¡·h"òOën	¸¤ÿ‰G²‘í ~–×ŠûŠ‰$¼no^¡‰÷Þd÷Þlò$°°S?õ¬$§ƒüÿ•­^_¼ÿ‡ÙÛÿÅ?ÿJôÿ£`Wÿ7‘¦'BðšxôŸb×elEü¬:ÿI›MÝCf¤X‡‘Ò‹¯nuTð¶žê¾Së©Çñß¾üÿó[}¾xÿ™XlŸÿirÿï8x{þ?u~>ü¿ÙêcU5ï]Hù51ðªÿ'ÞÛÿ£$þ×q°·ÿ‡¹ŒlÍ:ƒ÷Ìm.ìk±³uµ9‘|Øh£¶™ðòñùõ¢ZÌÅvgif:ûIÊüK“ƒ$È^€PüëO\$¾ïú¬UQ}¸l¬<­'À_bÿ QD°QÍVU”Í«Ái§S25RPå±Ç•ó»µÇž­½ƒ;¹©þj)p
á®×9(-nPß5ow7Á¢"¶#æ&qÆ¬u±¿÷·ÇãözÃÝ|/5XÁ-Þi°[@Ùã¸ÓO÷Põmc>ãpw¶¿§¦‘}Œ´9·T„Au‚tM]¹[Áãë%ù$œr÷n®ÈuNƒÒ¦÷^qqT\ÛV,'n»¤£+kŒÊMCµºñ‹PK…øÜÝ„*ÞÊöbì8;à D¹Í‹Ïq‚¿ g°aÈu*Þ˜‡pe¡/”WÐJÃÁ˜Ð´yüó¿ÑÂù'j„{ŸWù‡“fëHº_Á‡þ@0 ?ùóÏ‡„{5oºCóçÓNÓP:¸T,ï94y‘’t’Eû£â…õÿÍl€ŸÐÿÉþï‘@ô‚oü?ß® g ˆ 