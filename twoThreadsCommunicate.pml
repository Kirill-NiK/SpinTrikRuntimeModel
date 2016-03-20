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
#define lab_b3 Thread3P@b3
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
// формула LTL: p = (z -> z U a) && (F a -> a U b) && (F b -> b U c) && (F c -> c U d) && (F d -> d U e) && (F e -> e U f) && <>[]d

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

/* never
{
	do 
	:: (timeout == true) -> break;
	:: else -> skip;
	od
} */