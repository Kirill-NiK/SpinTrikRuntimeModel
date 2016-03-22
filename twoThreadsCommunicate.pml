/* работу тредов можно начинать используя provided */
/* язык PROMELA не позволяет создавать бесконечный буфер в каналах, 
   однако изначально мы предполагаем, что очередь в ивентлупе потока не превосходит N - можно проверить легко, 
   но большое N не получается */
/* может быть, создать процесс, который закрывает другие процессы, посылая им соответсвующие сигналы? */

#define N 100

/* для формул LTL */
#define lab_a1 Thread1@a1
#define lab_a2 Thread2@a2
#define lab_a3 Thread3@a3
#define lab_b1 Thread1@b1
#define lab_b2 Thread2@b2
#define lab_b3 Thread3@b3
#define lab_b21 Thread2@b21
#define lab_a21 Thread2@a21

#define b1 atomic{x = 1; printf("x = 1")}; b1
#define b2 atomic{x = 2; printf("x = 2")}; b2
#define b3 atomic{x = 3; printf("x = 3")}; b3
#define a2 atomic{x = 4; printf("x = 4")}; a2
#define a3 atomic{x = 5; printf("x = 5")}; a3
#define a1 atomic{x = 6; printf("x = 6")}; a1
#define a21 atomic{x = 4; printf("x = 4")}; a21
#define b21 atomic{x = 2; printf("x = 2")}; b21

#define z (x == 0)
#define a (x == 1)
#define b (x == 2)
#define c (x == 3)
#define d (x == 4)
#define e (x == 5)
#define f (x == 6)
// формула LTL: p = z && ((((((((z U a) && X (a U b)) && X (b U c)) && X (c U d)) && X (d U e)) && X (e U b)) && X (b U f)) && X[]d)
// p = z && ((z U a) && X (a U b) && X (b U c)
// p = (z && (z U (a && a U (b && b U (c && c U (d && d U (e && e U (b && b U (f && f U ([]d))))))))))
// (z && (z U (a && a U (b && b U ([]d)))))
byte x = 0; /* для LTL формулы, эквивалентой замене меток */

mtype {emptyEvent, signal12, signal32}; /* тут можно перечислять все возможные сигналы */

chan eventsThread1 = [N] of {mtype};
   
bool toggleThread2 = false;
chan eventsThread2 = [N] of {mtype};

bool toggleThread3 = false;
chan eventsThread3 = [N] of {mtype};

inline emit(thread, signal) 
{
	assert(nfull(thread)); /* Если копятся ивенты, значит что-то пошло не так... */
	thread ! signal;
}

active proctype Thread3() provided (toggleThread3 == true)
{
	mtype signal;
	progress: do
	:: eventsThread3 ? signal ->
		if
		::  signal == emptyEvent -> 
			b3: printf("before3");
			emit(eventsThread2, signal32);
			a3: printf("after3");	
	    fi;
	od;
}

inline handle() /* для проверки свойства _через_метки_, следует 2 раза скопипастить код этого инлайна */
{
	printf("before2");
	printf("after2");	
}

active proctype Thread2() provided (toggleThread2 == true)
{
	mtype signal;
	progress: do
	:: eventsThread2 ? signal ->
		if 
	    :: signal == signal12 -> 
								b2: printf("before2");
								a2: printf("after2");
	    :: signal == signal32 ->
								b21: printf("before2");
								a21: printf("after2");
	    :: signal == emptyEvent -> skip;
		fi;
	od;
}

proctype Thread1()
{
	mtype signal;
	progress: do
	:: eventsThread1 ? signal ->
		if
		::  signal == emptyEvent -> 
			atomic {toggleThread2 = true; emit(eventsThread2, emptyEvent);};
			b1: printf("before1");
			atomic {toggleThread3 = true; emit(eventsThread3, emptyEvent);};
			emit(eventsThread2, signal12);
			a1: printf("after1");
	    fi;
	od;
}

init
{
	printf("x = 0");
	run Thread1();
	emit(eventsThread1, emptyEvent);
}

never  {    /* (z && (z U (a && a U (b && b U (c && c U (d && d U (e && e U (b && b U (f && f U ([]d)))))))))) */
T0_init:
	do
	:: ((a) && (b) && (c) && (d) && (e) && (f) && (z)) -> goto accept_S219
	:: ((a) && (b) && (c) && (d) && (e) && (f) && (z)) -> goto T0_S218
	:: ((a) && (b) && (c) && (d) && (e) && (z)) -> goto T0_S217
	:: ((a) && (b) && (c) && (d) && (e) && (z)) -> goto T0_S216
	:: ((a) && (b) && (c) && (d) && (z)) -> goto T0_S215
	:: ((a) && (b) && (c) && (z)) -> goto T0_S214
	:: ((a) && (b) && (z)) -> goto T0_S213
	:: ((a) && (z)) -> goto T0_S212
	:: ((z)) -> goto T0_S1
	od;
accept_S219:
	do
	:: ((d)) -> goto accept_S219
	od;
T0_S1:
	do
	:: ((z)) -> goto T0_S1
	:: ((a) && (b) && (c) && (d) && (e) && (f)) -> goto accept_S219
	:: ((a) && (b) && (c) && (d) && (e) && (f)) -> goto T0_S218
	:: ((a) && (b) && (c) && (d) && (e)) -> goto T0_S217
	:: ((a) && (b) && (c) && (d) && (e)) -> goto T0_S216
	:: ((a) && (b) && (c) && (d)) -> goto T0_S215
	:: ((a) && (b) && (c)) -> goto T0_S214
	:: ((a) && (b)) -> goto T0_S213
	:: ((a)) -> goto T0_S212
	od;
T0_S218:
	do
	:: ((d)) -> goto accept_S219
	:: ((f)) -> goto T0_S218
	od;
T0_S217:
	do
	:: ((d) && (f)) -> goto accept_S219
	:: ((f)) -> goto T0_S218
	:: ((b)) -> goto T0_S217
	od;
T0_S216:
	do
	:: ((b) && (d) && (f)) -> goto accept_S219
	:: ((b) && (f)) -> goto T0_S218
	:: ((b)) -> goto T0_S217
	:: ((e)) -> goto T0_S216
	od;
T0_S215:
	do
	:: ((b) && (d) && (e) && (f)) -> goto accept_S219
	:: ((b) && (e) && (f)) -> goto T0_S218
	:: ((b) && (e)) -> goto T0_S217
	:: ((e)) -> goto T0_S216
	:: ((d)) -> goto T0_S215
	od;
T0_S214:
	do
	:: ((b) && (d) && (e) && (f)) -> goto accept_S219
	:: ((b) && (d) && (e) && (f)) -> goto T0_S218
	:: ((b) && (d) && (e)) -> goto T0_S217
	:: ((d) && (e)) -> goto T0_S216
	:: ((d)) -> goto T0_S215
	:: ((c)) -> goto T0_S214
	od;
T0_S213:
	do
	:: ((b) && (c) && (d) && (e) && (f)) -> goto accept_S219
	:: ((b) && (c) && (d) && (e) && (f)) -> goto T0_S218
	:: ((b) && (c) && (d) && (e)) -> goto T0_S217
	:: ((c) && (d) && (e)) -> goto T0_S216
	:: ((c) && (d)) -> goto T0_S215
	:: ((c)) -> goto T0_S214
	:: ((b)) -> goto T0_S213
	od;
T0_S212:
	do
	:: ((b) && (c) && (d) && (e) && (f)) -> goto accept_S219
	:: ((b) && (c) && (d) && (e) && (f)) -> goto T0_S218
	:: ((b) && (c) && (d) && (e)) -> goto T0_S217
	:: ((b) && (c) && (d) && (e)) -> goto T0_S216
	:: ((b) && (c) && (d)) -> goto T0_S215
	:: ((b) && (c)) -> goto T0_S214
	:: ((b)) -> goto T0_S213
	:: ((a)) -> goto T0_S212
	od;
}
