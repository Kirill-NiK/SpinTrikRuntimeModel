byte x = 0;

init {
progress:	do
	:: x = 0;
 	:: x = 2;
	od
}

never {
	do
	:: assert(x == 0)
	od
}

/* never {
	do
	:: assert(x != 0)
	od
} */