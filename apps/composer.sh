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
� ނ�Y �Y�+Y��z������Y�ݣ�G��*�{U���|�%u�.�\�[23�J�b#�`�$�,=�l@�5��1���C �����,��Gl���C��lK�c�����d׋Sx���/��{�D�)�*�P��,��/M6���4��� �&�'_��g���U��ٿ���a�=�8C�8C���I{�bT��06L~��O$Q�F�lU�}终�����y��ӗ�ӏ���	��� lȋ}�+�.]�j_ֺ�&�/����P7��������p2���~����L����s72]�@��� 0��1�c�$H!Ɇ8R�����.-�e��EYN��h"H�3͡�2�͆�H���<�u�7b�w[����e����G#���q�+��n�n^1�,m�
���U�p�O	�d��n�M��n�2�	RN{:H
҉�a���06 �\�O�;0�%�|��1?$J?��������!�~	�*�����������Uv
|�����
�k�-�ŨX�0?�فg��_!��&��"�w Q�(���C�q{Io���`; � D2&U�5QF�@(p)
���P�-��j�������y�He9�=��
s
��셓�Os�)-��}�牶Vޒ�9v��]QU�&p.��	W�2-o��w,�P�;��Ɩ��?�%��gQ�E�D���2���+*,V�R�D�c'����t�/�T�H�P�lZ�3�����w�Dwaxc���*�0��@�k�I�N��#�V[^޶����`�0{ n_�7>0ua���u���_ ��t0E�J���2k?���"���Q���G���7�!����~��R�g� 8���m���\����VZ96�l�9O�fЪ�K�c~�[�6��ްRA"����/a�_�yF։�Āy��Z0L����i�
�����K6���dQp[s� 5���խ����� ��$�C�bhN!`�ɠ��Y�A�����Xo{�& ��o ���	ء�����������%��aXl�U�� ��hê�E�u���*`gd��82�dS�X5b�1.AJ��:`߀ �ɹ] e�b��o��I	K����:h"o˖JV���]Kl�,E����l��17`3%���փ5eE�0�'p�L��v`����fx-S�������_��+}
�躢�n�w��oj�-h�
���r���2����x�]8cXڵvS��m���^?}�Ҝ�z���
��Hh�3�] �8��g��x��	��Ԑ�Z:�Nc���ոc 2�b��48h�s2�4N�H�+PG��Ca�R��SK��:kqЂ�H�J�s��;�ɰ����/�y���`Ā���6�bcM��b�9,�]l��&�f�u��,r

Ͷ�d��O��t9���K����F�x��	���2�������
�֍;���g��dc���������R'�["��-{�=�Y/9�r��]�����*p��h�mZn9&g����x�����J��^*����6�(7{w��ׇ�^��r?`�a٠렽�}
_���X���n��ES'J��1��p��R	�Հ` �ʞ
�%@on��4?���6����<��~��ސ&FL;b�wb���+[�2D��0Y���.��g�
�t�?��V��F^�t���n�V��.�-��$AQq|�}��U�[���^<a�ܫR1_h��W�ن�5��ҫ[��*�n�ɖ�\��6�}�ky"<ż:�
�L�f�\�^%_]K��-p��YH���u�c.SdK��gǜݩ�*�y�Me�[��r�Y�g�m*q�f��y×�n��"e�TzUl��J�S�2U ���6`u��K�����J�\=�U2���i�+7a�ƥ _���C��9�~Q:�Z���)�
�WO�~i��?��P����e{��R7׋��w9�8�Zl\N��¶0��oC:�:S�	��i0
�j�T��R�?�M��Dܪ��?�����ݰ6���Aӏ%O�v���k�_;�������>y��y�SǸi�����Y�Ż�0,�q7mŒ쳻z}0��vR٠�1@{��D�H�Cq�~�x�ē[�[�W���3J7��hO�H��?jŭw䉪����o���x����='�o��(LDa�@a\c��3���� =?@�����׎�U����2��8�j��q�3֜�/�<ϖ??r�M��a�1z���e�S��V��]��9��)ڕ͜����_i�*�ȧ���So������ʺ�'���>{�?u���i��L}��}jw�g,bΆ���+�=A����8o.�����{�M�ێ��Y)s�W����2=�򲑐��;d��r�ѳ��y��Q�>Z$��#�C/h���:���dxf�	��XUg�1�Z��@�VV1P��l�x����E6�j��/Iv�d@x���gم��.��a`O�7^V���ݧ����}7P���0݋*�3��M:}�4�y(�i̻�����V�
O�K�Z�nsגj�ߟ��{2І�.�3��׍w�¼�@���BA��e,��׀�t5_qt�t�5
td fun3;~ב��� ��gע�r茰nDqO~0�}���׈m���:��`>
mM ��q\��k��6��LX0�m�Zϸ��4�,���t��5l�� �������ѧ��h`u���\���7�h��b���0���.o]x��O� ��M߇{ @ ��Ƨ�L�[nl
K
�ƪ������)oUM¬�:,��?�߳7��ߦ� �+�C��F��(/Iј?vA�k���� 1t�f�����>���j�ޙ����/�gv1k6�T�*`
��O��E�
nB�?(���<@����Q����Ï�&��:���Hּ����Y	�S7i7ҍY�Y�H����t�(���e�.X�܊^Q�קw,<�ṫ�����U�թ���B�	-�f�[�r���yM��`�!�#��h1�wa�v�;ִ�`�c=^`
?�$tN��,_po�bׯi{�n0�|�ͬ�w/=xz�v>0��wP��E+o��P+��g��7�j�{�!���Xv<_a�K�o���k�+{��j�ӗ+��-�r��ݭx�G!�o��V�+<�f~vبVb�ub[�̞]�
��9<c���hį}��<F�F�(�*%�~�.�%
�L������hǜ����0� |qj���^}���/�:�[�y
F|��=GW�[q�^1�^���M7�@��,�Tk�#�ŶAA��w���a��2�?�i77{z�井�����U�	�/".��o��}�+1V�E}$���w%���Y�$���i+���gV
�a7���^�R�;׶Pr-A�R����./�[v٫�o}����t��'؃9���.�/~����J��׵���쭼��|�ǆ��O<o��3_�Y���d�m�`��[
K(�N��
��W�/�;�k/8�Yu	���=����{o��*v�uc�]ߘ��_��`�s/�X����k1�������W�:`B[·^���ѯ}�~��� ��O"�:tT}jX���Ձ�I��������߁��}��0(,A%��	�!�A��O`���\��0��9��	�H#}��*w	l?�����X��J2)&�#dL��Kg�}�y���o���
���"�he?�8����LR�)<&�@ߥ��%��\C�CRI1��%�
��T]����j��9��:��0�7`ț=�q�j�h�7�������T^5�뛘��H"��<�?pm��j��|�u��|�$��aT��=tKd,�&d��c<%��(�#�I�I���NL&O��������Bu��MI4�R�$
7�������r�%��ǥ�v��۬/��~�%��6�Yk[oG�2P�M�=_^��}��
�Aqj��M���&h��H�vt��da�J�o�ۅ9n�^&g!��d������3h�[r$_|�Ѵ���X�E��a2��8a`��"�;�$6N�r���#�`a0�Pl��T��W{YfL+�3O�G�|�����/��K�+3�Uu�Wc�&
:!E�l7iI��6�L�N�B'&HI����Y�b#�*5OS2F��%��q7������*�ɍ0G�e 4�"�?�Ά3(c{�lE�VE�5�w�vi`�}SxY�o�u�	��$a#� =J%D:&3�$�Կ�۱�(���\kP/��z���9n`S��ه�W�J�k\�od
, ����4���E��Ʉ@Ē&��
աxQ` .bjӹ��s�&��V��f�{G�#>X�Kk� ��)��J�{2����G9$n��P�k � ��1����5��.�jO7̗$`?q~�|�o�� ֔������A�f���-��������qZ�W�x� � �{��=�0S-W\�U�mp� ���$�)�_��CY[��rc�OW6��X:
�ș�@PN�(#]@~�D����L��*n�+��f���[�c*��\bbM��]���Wko˯<��쯿��
=�r��ě���S���i�����
:��
��3���>2Q�O��5���/�q0u�VhlG	ko��֛���2Wm5׷ڗ,��8�>3d0Y���J|�?�)��[��O���ϰ�/>��
��>� �h��w���k$=^�d5f^�T���?a��?##�o+��?�F^!_�������?�[������v&��_�	I�H%;".�d����T��)�$^&q��ɔ�J�"O��T
�$EI���������`�{�ޟA~�UE�\K���w��VG]|���"H�[�Le<����o!{�Ib�����������η����#�c�5��o������!���@��_ ͯ�G�	��{���]x��mw�e'�M���vm왷a��ߕ5�P����b��:�_�8��V�?ED�+�쿏&�J���4�7��?k��~����?��k�����������_�����G~G�:�̐���֏�h�?�h�o��a��h���/I:�LH2��dBbhF�I,A2���S2Mј hE�)�����~��'S�� ? ��{﷟��t�;���O������߻�V������p��Ð����ml��	��Ud���?��ݟ�-�����{��!�w�����r�x�{o�O����C~���?��i._����,���Y�H�X��.2Vt�i1�v���P�%��S=LdʸhM�Y�(��^����Z-�^���1E2���I��禇'�9�,��X��e���3���DPó&�.�kV\��\i�q�;�!gm�?�\s�̽rMHj�����)��Ҡ2��XN�V���<#�1���sS�2g����U��F�/�y6��j�0�\(_e��a�[9I�gMV=i���)gw��M�ٳ���|��	�W��Ms�W�xt��ֵÞ0�E�2)�����Jp�]�A�ū���<k�S!��)�\�N�]+M�*g
UfΙ��4��4��Q����9������E��.�Y2������?���-t�l�Z �r��$9��e��ZA�i�_����`tΏ�t1�BF�Rz4��X�����e�8�
$Ϗˬ�����u�2��k�8��H��^
�3�L���N�{���-RrCk��'�IF�w��uD���L�s:7�ⴜb�
,��=��>��n\(�,d;��MN�x=����t�r����6[e;ģ��%^��R�j�@�sփ��r�lcփ@޳�IN����
����?�����kX=��Wi�tp�W���-�b�NrE=�.}I��(���%�)�"M�Z<y^��R��t��p���F��~��܅�0�:�9Ȱ)�T��L�U�P�B�g/�S\d�"=M�j�ӵ��&d��#c.��e|@R]jZ5ҭ�4����)eF%��$N�3E��İ��Z)�	��W�N�uު��cD�:Y���t2�I�p׬���_(~~����{��}���;O��
��BP��Ƌ�֠V�J\�T5��^}������[�t���������'���Tz.D�*M�f�\��=�U.�Y%۟UT����"lzr����l����X2�{�4����Vǵ��X8�U!燉��dJ;wlN��z\:&��Fs\99��4�!WJ�~[���r{��gI$]/����>8O�@����Y-�d.���
K7�.+�2g��p�-�S[P�lA9Sf�鑽X.ҙڴ�����L���1Y��
W���0������b!ҭ��I7�?,���(�^+��2?>O��r��D>,��͖4���I':�逿</s��z�	L7�$��B����"ǰQ�MM�����Cǈf�F���y��;����k�҄�d�d$��dPj�
3.�tI���T2��e$�4�:��*�ʏ*��	���Z����2d)_�Lx���̤�y�� ^��f��8��։x���8�c�Hm�Ԉ�c�!�1�N�HN�k�b����!Ϋl�qV�Si��Wh���Oz��:O�'
���F��l�P���0�U:k^&ҵKm>�e�nh�Z�p/Ԩ����#�ϓ�B3@y%M�JJ#�ƻ�!U��8%����&{z��:f'�T	J����0�J+Χ���3l��i9M_��9v�ų�:k����T��U��u�i!�&�r鳽?d��=r��~�+�-2���yK��֙2𿁼�Ȣu�0G�����;n���|Zse��X�ޏ���|��U}�dy7͛b�������;ȏ���k����]��s�oZi��@�������|�X��|��0
[��<ʨ��<����>����������z�:n����D���dD���
 R/QO�<���tY���R�(.;��HZ�.� ��E�Ϭ2r/G�H�� ȣ�s���@[T�ÝEavQ/Qq4��;Q\_�|�q��Co��[��N.�1g֬Yk�%����H�Deȫ/�:��̕�\YN�Cqvm:!}�x"�m䆁��Q��c
'�ƅ����
��J��j���c'���Px�'@�܇v�}��$t��w��[]Nv
��������Ǵa�d�:l�f��	^n���(�Z��A����+e0�U ��#x?Xg��[č�rJs
�1om� �yx;�6=3� �c冯�+�T(����
���BZ/�^ݒ�M\6,�$qN�f��T-���;���()м�"��ۇ�n0�F�0N����zJ�;5B�,V,Oy�B|Ͷ�-�c���P8�9#r��KO��އ�4XU��4�`GXnq ӳX� �2<U�M�%�2d�x�Һ�@�M�l�� �8��0��2���%��pMW4r���˘ %����(��y�fB�,g�m�$uWf�ds�����K�Nl��Ƕ�
x��;�j����4�75�޾�r·e������;
����D":����c�_�t�[R��Oql��ם��_g�'^\�p�!�'h�
D^�fzm����f��	^d���xV��P���^�|�(�ڱ��݁����*��#��
��h�o�r^�_������1���;�� d�[�3kcU}��w:��د���29U��e
1#����D�4��8������y�7W��<.�s_�:n"W)�LV��Ⱥ1²Ӫȱ�+:#g�w�m3�d��f���F�c?��Ǚ�*��"��
�OD��[������-#�������?6�'��o���V�Q�?4>� ������?:��C�D��������r�G���G����t����.���r��ö���H`D���
���z�C�#�������������o���V��忾<3L}$G�G�H���]��	|��AF��;��L���'�N��E>��e)�	D���p���L�.v0��:J���SI��h:z&|����w��o	���&s�4RK
���!3GN�ؼ�Wx���0N����N?'��������`���I�@�xn4�V���h���*��S�io�M�|e2��yR!.��CS��ss�]��OO�Ng������������߷�]��r�sd��
<:�7�n���x��?��v��S����;D�CRD��ovb�7��~4�i�7���������e[?*�L��h���a��,���Q������N���{=ae"�88��n����#���<91.s��lDkG<�;J������ׇ�F�ȟU����$�G��DO�ٙpf�{��I/N���B��V/3
v�����ۀ����t����q�XTC�sitv"_�c��J���bG"z�i���V���
�&�
�[!��n;�����"����v�t�sWa[���������7��g���F����?��������e�`��?�G��m�N�&��������g�������������G���������[�Ǣ�����{����������ǃǤ�<���~T��D����!����[���+	"������]���������&���|�kq�C��0^,���T⒥��������EzX�S$c;K���Ik�5ˠ"��I��jD����q@
��A$M�f�\��=�U.�Y%۟UT����"lzr��\�dS��s��+���i^�k��B[��7��#�{應��dJ;wlN��z\:&��Fs\99��4�!WJ�~[���r{��gI$]/����>8O��_֊Ǭ�T2��y��g�����W9 �y�>��\��WX�{l����c9~"��fKr�
J�c؎�ͦ&�H���!�cD3S������7ߍcc�	���F�?lS����z|����[��	����'���
�����<��O���HD�?�7���9<��/����4��q�=�pL���:�7���|��������i9�r�~T�s�y�ݹ�ZB1�Zz��
̘�Ї�ᱜ��!)��lO��� �TXQ8+(��\9�4��h�S��d�d�=?��Jqxx�} ���p�} !�>x���4�*l��?Ȝ0����K�ؽ�e�r
��i�eLH2ŋ)�`hI��;��I$)Yf�2.����)�P���0&Ac4]�1����)���y�M�2=�%��0kfΐQ�B�TuxD0)>K(��Iל`�rƽ���u��������e+i�ϻ�U��O�H%#K�$6��u�0�P)�ܮws�I�Z:�%N����&3�Y��L����P���-��'������+���P����#�.��H�{<�	�O�������A�#��ǂ������
�d:w:8>��:qYVyi��k�8�4��F�wt!dӗe���3��Neѳ�d�r�gOSw��r�tM�Zn�ӳt��*�yϲ�,ش�H�S �;s�;̲J��2�W�C<2_�|9V�X���+��H��Z^̕'��S�Ԩ'_
	1~y�iI�|:G]��|_��8lk�D��n��1��A=��p[������R���1
OD��ۀ�}�Ž���M�?A1D4�ۀ]��q2������V�ͯ���v�1�w��$������'���_��_[���<�4����I��x	�w{b|��y�&S2�%餜�	#p�O��L�$#�<�����ov����p,��i�9�
���8lQg��y�@(E NN��U�2%{��rNWʤ^�d��Өg��a�;�5s�k��96�,$'�:�
��X08:߽�-���4���,��ۀ��j��7y���-{(T{�d��TS�2.Z�tv�������v^N���o5!q���7�<N�b9��N�M�@��'��R.���m��x���������J���W�uuKw��4o��g���e
O���8�qH�F��Y:��������p�H��^�7�sʜ6/φ�>7+�b+;T
�y�o�y�^F��1����D����	�O����n�C�y����������?6�'����ǂ���(@d������'�r������d��C���Y������I�`&����~�(:�Wk+�?��C���7�S��'�O�����w@
Y�w��J)
��0�}��-{SS6�ڲ=��N9��f��]k�M�M����9r��u4?N]�kx��h�O�҄��*gG�ʤ�=�]o�Z��>a�z�s��G9^j(
UfΙ��4��4��Q����9������E��.��H�@h��e����j��e�ò���~9s�Ӄ�9?f��t
�K����r8h�b��VGX&G��*�<?.���[֥"X�-s�L��!���d���<��$?OQ�T���0�"%7�vkz��d�x��mPG�>��$=�sC�+N�)f�@NOʅcSf2�L�J��~����
lG�����U����[���O��XD��ۥ��#خ�.��a�_	2�����W���E�_��$��9�/z�sW!���n�o����x�u�o��YvvB�'B�*���7���,���?79m��T�b�ӕ�9��3�lU�'E�_n�_���
H������v��%B�c|����Q ���9!������@���S�"��� �r-������?���$���@�?���������O� ��2-݀d� ������ ��1�����(���F�GIF�#%3I!�I��lV�4L!-�Q���|*-��H�Ŕ��g�
��D�Il��A俟�O��xK�o1:�V4K�t�����٠7����C���Q�oݘ����g�u`1Z�ާF��`NӣB�f���q�Y�jtV��U���17#��Xq~}�'\��^���c��27��Y8���Ϣj���"�?�����G���r�3�8�������$Y����I�?��'��$��D�{���6q���'�?�1�?��� ��GA�����I����X򟕦���O^���D��z�O⿜
'��8�ߩ��C��"�O.�I��! �ǯH��Ӏ�"�O.�I��!X��?�y?K����%���Q����q+r�vS4�VR4WZ��iE/L������$��,���P�5�ԯ�~�Ϩ_���]Y�c?,W����_%Y/�ܐz5�C��T��6S�,���@��Ӎk�zu��R�1u��]��Zmr5H���膯��"/u%YO���"�it��.�:�a��*ɋ�]�����D��>y����ܖ���rSc���\%���Nm��N�g�.+|�i�\1UWb��r����Qd�^�s�6�0����{�w~�M^e�cmx��W���]��윓�rE�&�)}ڸ\IzQ/��BeQϦ�.u=��[<���D6=���GC �?�g�����ȏ������_ ������A��?�r��O2O�$H����5����8����_
�q&�?���l&ͻ�"����������[���!w?����F8UX�ܽ�͵jҎ1��\>3��g�u�r��J��q�5ä������*���J??SMZl�yپ��&5^��y��_�a��O���1����͵�G�}��p��wéC8|s�[wQ�g�n��\��e6�&�gJ��2��Y�3%1���l����U��L��n��%-��gB��\Z�Z��^�j�ꙁٍ�n������S�/F��c  ���LK7 � 8������ ��x���9�?
�$�&��
>N��E[����o�,XU���Ѕ�>Q�@����j&W$�Y�H��9`g�8��X�F�P����j4����0�Ñ�)x�����/+��;y��K�|�&����m��y�C�a���|� ���W�s��n;�ߺn\b�;��3�]A�U L @U_��n ,jThA��͑AhZߩ5NSΝ�x`ʺii��x��������T�5�w!�MKދ~e�]��)��r����&�w+����O�`�X1�	E�@,@�T�Cħ3U��.	���@��J�
nJj-t��
U�������mŀ��;܏�8��I��G���/9��)�Cc�k.m|n:"�W�8m����򺇈�au�������8/�@�˭���j}ugGy\���{�o�"���A�\J��=�b!����X,�Տ�vΫ6���ЧNcp��E�ْ�)	��W�W`@s�	m�U��H{G����H��3e�N��!���E��NWvg���q��nj�p3�涪�������|�x��m���<_��p�p�������YhVz$@�S݀�(��<"�U4 j������J��+�@���-D�r����W�@���I!7��ۚf6dw��h�[=�%n�fO��:+!��d���y�x/��&�%���߿x�y�ܲ��gՊE�eآ喏Y��f��D�`CG������<a�F�-0�-*�j��������`�{�y"�tJµ�l@���Α��à�B�����ޅ�-�i����b�b߉rz�dp��0�W��x��Ar���e�tkh�߿��<M߿���;��:�~��A����ߙ��Ƽ$9v�	��}�9�ݛ�W����%]�@#�}��~��O����b�T�!��1�g��9�k��I �
�dD���Õ�4�#�d��\1t
�vV��u*�-�ޖ���EZbԷ8�&}2v�A��?5XT�Oc�O/���x�J��7[���J~��j�����c1�œ)!��B2��A>���(��"1Rz��|L����1I	�l�O$2����[sB96�
t�1����q�U$��6��HA����x��[��~�H&��$/���i���L�4��y>�Jda�Τ20��)���Hf�0����!��s��������:�1�U{
w�+��'"=?�7�hX��ƭ�N�Q1J�mF<����>	_�X/�al���DեB��ak��f�Vjl��d�n��`��N�۽�#�Ϧ��v+�z�Wn�/0���ԟ��a��ە+,C
��<�csl�p��\q�Ͻ��k��r>����� g���d6�xS���n�Q�$썞8Ft|1�U>����IB_��I�9����c��u�?`��Į?��s��<�d��>��Xq^9�Kp5ɼEZ�v8�[)�;�$�0�P��j��{Y�l�ؗ8{3���}�Q>w���P���3��0^��d�N!6?oq���������t�VT)b-��~���Lb��#�����j�zd�M��ǀ��~
.1�nM�"Z� ��u��6�����s�x�T���@X���m�2�Y�_K{�Dn�kT7Eq�v�����-Tt"��ϕ<ؼ��|Hא���\o�Z�LD��!u����S�}���	���3*(ZT��1v�(,�F�aZ �n|3C�,���F�1#>;	�9�R2x���m���Hs���+
[E�?>Q���٫��
����=���_�f	}�(c
���_4���:�Qg�|#6��7���܃
%��9�l�O�]���w�Ӄ	\
����	�N��1�nb}�Jw���o�K2���i!*�L�7��f�s4k/d����wu��p�?��]����bo
�c����v������j�Ι0��*:��#��	���Cr��=q��/�M�yɥ�~��?�����)�����c�P���s񿶳Ƈ��K��D~^;�Z6j�s|��N��d5�Gra�<�P����܇���~���"��$����ku�l6�<��򿳉�3����?�J����C�?~����B
����;e�Ξ}�Z�n����m�x�.���i����?a��P�
 ��F%�m��N%y���G6�+�Թ�$l��6�5⿔���'����oA�����C�����4M�� ��+�o��̕iA��#+��^���	v�F�9(��P��p��]��LĪ��O?����~e�۫�q4����8�0�K�}7�
��� K�����\Ѝn��SL�� ���,�������o��c�7���_1:�X�3)������c��1�SbpB��8N��7��ӝ��M��0]Wm�Z�Ϟ&`Ɍj��>�~.QgofX�y���g�/C�˰��Ȁ轂�
���9(-nP�5ow�7��"�#�&qƬu�������z��|/5X�-�i�[@���O�P�mc>�pw���