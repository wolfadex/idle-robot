production: main.odin
	echo "Building for production"
	odin build . -out:dist/idle-robot.exe -o:speed

dev: main.odin
	echo "Running development build"
	odin run . -debug -out:dev/idle-robot.exe
