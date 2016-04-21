//#define NO_LOGGING // только для QLOG_INFO()
#define S 2 // максимальное количество запущенных скриптов (engineThreads) S < 256
#define N 4 // максимальная длина очереди event-ов для каждого потока N < 256

#ifndef NO_LOGGING
 #define LOG(x) printf(x); printf("\n")
#else
 #define LOG(x) skip
#endif

 /* enum State */
 #define ready 0
 #define starting 1
 #define stopping 2
 #define running 3
 
#define mutex bit

/* ниже будут описаны дефайны для LTL-формул */
#define p1 GUIThread@showError
#define q1 mErrorMessage
/* определяемые ниже метки для проверки необходимого свойства нужно проверить снова при расширении модели User-ом */
#define p2 scriptWorkerThread@doRunInvoked
#define q2 scriptWorkerThread@completedEmitted
/* r2 можно переделать, но для S==2 пойдет */
#define r2 (isAutonomousCycle[0] || isAutonomousCycle[1])

byte mState = ready; /* ScriptEngineWorker:state */
bool mInEventDrivenMode = false; /* находится в ScriptExecutionControl, True, if a system is in this mode, so it shall wait for events when script is executed. (c) */
mutex mResetMutex = 1; /* мьютекс для mResetStarted; поскольку все операции с тредами должны быть атомарными */
bool mResetStarted = false; /* флаг, показывающий, что начался reset, во время которого все остальные операции с тредами должны отменяться; */
mutex mThreadsMutex = 1; /* для mFinishedThreads, mPreventFromStart, mThreads */
bit mFinishedThreads[S] = 0; /* список завершившихся тредов - у меня будут инты, в проге - стринги */
bit mPreventFromStart[S] = 0; /* список тредов, которые ещё не были запущены, но должны быть завершены - у меня будут инты, в проге - стринги */
bit mThreads[S] = 0; /* хэш (который мы моделируем как массив), отображающий имя треда на сам тред, используется для получения доступа к отдельным потокам; */

short threadId = 0; /* имя треда, для :main: engine thread - 0, нужен только для модели, равен самому левому нулевому значению в mThreads */

/* ниже используемые сигналы-события для всех потоков, параметры - в глобальные переменные, если необходимо. emptyEvent --- для заглушки */
mtype {emptyEvent, INVOKEdoRun, completed, start, runScript, abortScript, stopRunning, stopWaiting }; 

/* ниже каналы, моделирующие очередь событий в соответствующих потоках */
chan GUIThreadEvents = [N] of {mtype};
chan connectionThreadEvents = [N] of {mtype};
chan sensorsThreadEvents = [N] of {mtype};
chan scriptWorkerThreadEvents = [N] of {mtype};
chan engineThreadEvents [S] = [N] of {mtype}; // можно смоделировать удаление mEngine->deleteLater();, а в других методах return mEngine->isEvaluating(); нет проверки.

mtype {FailedToOpenFileException, returnControl}; /* бросаемые исключения и возврат из обработчика (returnControl) */
chan catch = [0] of {mtype}; /* рандеву-канал, эмулирующий обработку вызванных исключений */

bit abortEvaluationInvoked[S] = 0; /* массив, который обозначает, что engine->abortEvaluation() была вызвана. */

byte mThreadCount = 0; /* число engine-потоков */

bool timerTimeout = false; /* флаги, моделирующие ивенетлуп в ScriptExecutionControl::wait */
bool loopStopWaiting = false; /* флаги, моделирующие ивенетлуп в ScriptExecutionControl::wait */

bool mErrorMessage = false; /* флаг, который будет true, если mErrorMessage в программе непустой */

bool isAutonomousCycle[S] = false; /* массив флагов, сигнализирующий, что какой-то из потоков может находиться в бесконечном цикле ожидания */
//bool autonomousCycleExists = false; /

inline emit(thread, signal) /* в очередь событий \a thread добавить сигнал (событие) \a signal */
{
	//assert(nfull(thread)); /* Если копятся ивенты, значит что-то пошло не так... */
	thread ! signal;
}

inline lock(_s) /* блокировка мьютекса */
{	// в дальнейшем можно приписать метки, к примеру. и после этого проверять, что после каждой метки lock идет метка unlock. или сделать массив мьютексов.
	atomic { 
		_s == 1 -> 
		_s--;
	}; 
}

inline unlock(_s) /* разблокировка мьютекса */
{
	atomic {
		assert(_s == 0); /* из документации Qt --- неопределенное поведение или ошибка */
		_s++;
	};
}

inline throw(exception) /* моделирование бросание исключения */
{
	catch ! exception;
}

inline random(min, max, x) /* рандомное число записывается в x: min <= x <= max */
{
	atomic {
		assert(min <= max);
		x = min;
		do
		:: (x < max) -> 
			if
			:: break;
			:: skip;
			fi;
			x++;
		:: else -> break;
		od;
	};
}

inline tryLockReset() /* Threading::tryLockReset(), но не возвращается значение, ибо inline */
{
	lock(mResetMutex);
	if
	:: mResetStarted -> unlock(mResetMutex);
	:: else -> skip;
	fi;
}

inline abort(thrId) /* ScriptThread::abort() для конкретного нашего потока: thread->abort(); */
{
	abortEvaluationInvoked[thrId] = 1;
	emit(engineThreadEvents[thrId], stopRunning);
}

inline joinThread(idT) /* Threading::joinThread(const QString &threadId) */
{
	true; /* костыль для использования метки в начале inline, взято из официальной документации */
	joinThread_call: skip;
	short tmp;
	random(-1, S - 1, tmp);
	lock(mThreadsMutex);
	do // возможно, цикл затратный.
	:: /* длинное условие, которое, возможно, потребуется явно прописать тут, для более адекватной модели */
		unlock(mThreadsMutex);
		if 
		:: mResetStarted -> goto joinThread_return;
		:: else -> skip;
		fi;
		lock(mThreadsMutex);
	:: (tmp != -1) -> break; /* крутимся цикле, пока не будет reset-а при t == -1 */
	od;
	if /* mFinishedThreads.contains(threadId) */
	:: unlock(mThreadsMutex); goto joinThread_return;
	:: skip;
	fi;
	unlock(mThreadsMutex);
	if 
	// вообще, это неаккуратно, вдруг на mThreads[tmp] запишется другой тред, но правка приведет к сильному усложнению модели, поэтому допускаем такое вычисление.
	:: tmp != idT -> !mThreads[tmp];
	:: else -> LOG("QThread::wait: Thread tried to wait on itself"); /* данное сообщение выводится не в логе Q_LOG */
	fi;
	joinThread_return: skip;	
}

inline killThread() /* Threading::killThread(const QString &threadId) */
{
	true; /* костыль для использования метки в начале inline, взято из официальной документации */
	killThread_call: skip;
	tryLockReset();
	if 
	:: mResetStarted -> goto killThread_return;
	:: else -> skip;
	fi;
	lock(mThreadsMutex);
	short tmp;
	random(-1, S - 1, tmp);
	if
	:: (tmp == -1) || !mThreads[tmp] ->
		if
		:: (tmp == -1) || mFinishedThreads[tmp] -> LOG("Threading: killing thread that is not started yet ... will be prevented from running");
			if
			:: (tmp != -1) -> mPreventFromStart[tmp] = 1; // тут не совсем верное моделирование, то есть может так быть, что в prevent попадет всё, что угодно
			:: else -> skip;
			fi;
		:: else -> LOG("Threading: killing already finished thread, ignoring");
		fi;
	:: else ->
		LOG("Threading: killing thread ...");
		/* ScriptThread::abort() */
		// так как множественный stopRunning не падает в реальной модели, запретим "лишние" emits?
		abort(tmp);
	fi;
	unlock(mThreadsMutex);
	unlock(mResetMutex);
	killThread_return: skip;
}

inline clear(_arr, _len) /* обнуляет массив длинной _len */
{
	atomic {
		assert(_len > 0);
		byte i = 0;
		do
		:: i < _len -> _arr[i] = 0; i++;
		:: i == _len -> break;
		od;
	};
}

inline script_run() /* ScriptExecutionControl::run() */
{
	mInEventDrivenMode = true;
}

inline script_wait() /* ScriptExecutionControl::wait(const int &milliseconds) */
{
	timerTimeout = false;
//	if
//	:: run Timer();
//	:: skip; /* означает, что время поставленно очень-очень большое */
//	fi;
	loopStopWaiting = false;
	timerTimeout || loopStopWaiting; /* loop.exec(); */
}

inline script_reset() /* ScriptExecutionControl::reset() */
{
	mInEventDrivenMode = false;
	loopStopWaiting = true;
	/* удаление конечного числа таймеров */
}

inline script_quit() /* ScriptExecutionControl::quit() */
{
	/* два коннекта - с сигналом и слотом */
	byte runningThread = 0; // можно сделать стоп раннинг в случайном порядке. надо?
	do /* --- с сигналом, по всем потокам вызываем stopRunning */
	:: runningThread < S ->
		if 
		:: mThreads[runningThread] ->
			emit(engineThreadEvents[runningThread], stopRunning); 
		:: else -> skip;
		fi;
		runningThread++;
	:: else -> break;
	od;
	/* ScriptEngineWorker::onScriptRequestingToQuit() --- со слотом */
	mInEventDrivenMode = true;
	stopScript();
}

inline threading_reset() /* Threading::reset() */
{
	true; /* костыль для использования метки в начале inline, взято из официальной документации */
	threading_reset_call: skip;
	tryLockReset();
	if 
	:: mResetStarted -> goto threading_reset_return;
	:: else -> skip;
	fi;
	mResetStarted = true;
	unlock(mResetMutex);
	LOG("Threading: reset started");
	/* mMessageMutex.lock(); ...; mMessageMutex.unlock(); --- пока не знаю, надо ли моделировать, но не стоит забывать */
	lock(mThreadsMutex);
	
	byte k = 0;
	do
	:: k < S -> 
		if
		:: mThreads[k] ->
			script_reset(); /// TODO: find more sophisticated solution to prevent waiting after abortion (c)
			abort(k);			
		:: else -> skip;
		fi;
		k++;
	:: else -> break;
	od;
	
	clear(mFinishedThreads, S);
	unlock(mThreadsMutex);
	script_reset();
	
	mThreadCount == 0; /* waitForAll(); */
	/* много удалений, связанных с очередями сообщений */
	LOG("Threading: reset ended");
	mResetStarted = false;
	threading_reset_return: skip;
}

inline brick_reset() /* Brick::reset() */ // очень опасный метод!!!! Очень много вызывается проверок, мьютексов и т.д. при остановке.
{
	LOG("Stopping brick");
	brikReset: skip; /* остановка по всем сенсорам, дисплею... */
	// возможно, отдельно стоит расписать для Keys->reset(), так как там есть lock() и внезапно, запуск может не сработать?
	// для дисплея:
	do // должно дополняться любыми INVOKE-ами, отправленными к GUIWorker-у
	 // :: перебираем все ивенты в лупе и посылаем обратно. заводим счетчик до 0. если сигналы определенного типа, не посылаем, но уменьшаем счетчик. 
	:: break; // если счетчик равняется 0
	od;
	/// @todo Temporary, we need more carefully init/deinit range sensors. (с)
	//for (RangeSensor * const rangeSensor : mRangeSensors.values()) {
	//	rangeSensor->init();
	//}
}

inline stopScript()
{
	true; /* костыль для использования метки в начале inline, взято из официальной документации */
	stopScript_call: skip;
	if
	:: mState == stopping -> goto stopScript_return;
	:: mState == ready -> goto stopScript_return;
	:: mState == running -> skip;
	:: mState == starting -> mState != starting; /* -> mState != starting означает цикл, ожидание */
		/// Some script is starting right now, so we are in inconsistent state. Let it start, then stop it. (с)
	:: else -> assert(false); /* mState в программе других состояний не имеет */
	fi;
	LOG("ScriptEngineWorker: stopping script");
	mState = stopping;
	script_reset();
	/* if (mMailbox) {...} --- умышленно забиваем */
	threading_reset(); 
	// if (mDirectScriptsEngine) {...} - забиваем на runDirect пока что
	mState = ready;
	/// @todo: is it actually stopped? (c)
	LOG("ScriptEngineWorker: stopping complete");
	stopScript_return: skip;
}

inline findFreeThreadId() /* только тут меняется threadId и он равен или -1 или самому левому индексу в mThreads, который не занят */
{
	byte i = 0;
	do
	:: i < S && mThreads[i] -> i++;
	:: i < S && !mThreads[i] -> threadId = i; break;
	:: i == S -> threadId = -1; break; // возможно, если хотим использовать byte threadId, стоит отказаться от -1
	od;
}

inline startThread() /* Threading::startThread(...) --- в этом методе не важно, что за имя треда и функции нам передают, поэтому выбираем недетерминированно */
{
	true; /* костыль для использования метки в начале inline, взято из официальной документации */
	startThread_call: skip;
	short tmp;
	random(-1, S - 1, tmp);
	lock(mResetMutex);
	if
	:: mResetStarted ->
		LOG("Threading: can't start new thread due to reset"); 
		delete_engine: skip; /* delete engine; */
		unlock(mResetMutex);
		goto startThread_return;
	:: else -> skip;
	fi;
	lock(mThreadsMutex);
	if 
	:: (tmp != -1) && (mThreads[tmp]) -> /* если тред такой уже существует */
		LOG("ERROR: Threading: attempt to create a thread with an already occupied id");
		mErrorMessage = true;
		abort(tmp);
		unlock(mThreadsMutex);
		unlock(mResetMutex);
		goto startThread_return;
	:: else -> skip;
	fi;
	if
	:: (tmp != -1) && mPreventFromStart[tmp] -> /* если пытались ранее убить незапущенный тред */
		LOG("Threading: attempt to create a thread which must be killed");
		mPreventFromStart[tmp] = 0;
		mFinishedThreads[tmp] = 1;
		unlock(mThreadsMutex);
		unlock(mResetMutex);
		goto startThread_return;
	:: else -> skip;
	fi;
	LOG("Starting new thread ... with engine ...");
	short myThread;
	atomic {
		if
		:: threadId == -1 -> unlock(mThreadsMutex); unlock(mResetMutex); goto startThread_return; /* искусственно запрещаем создавать больше S тредов */
		:: threadId != -1 -> skip;
		fi;
		myThread = threadId;
		mThreads[myThread] = 1;
		abortEvaluationInvoked[myThread] = 0;
		mThreadCount++;
		assert(mThreadCount <= S); /* Изначально мы считаем, что максимальное количество запущенных потоков engineThread ограничено */
		assert(mThreadCount >= 1)
		findFreeThreadId();
	};
	mFinishedThreads[myThread] = 0;
	unlock(mThreadsMutex);
	run engineThread(myThread);
	// connect(thread, SIGNAL(finished()), thread, SLOT(deleteLater())); - надо ли?
	emit(engineThreadEvents[myThread], start); /* Мы переопределяли run(), поэтому отдельно расписываем thread->start() */
	/* finite cycle removed */
	LOG("Threading: started thread ... with engine ... thread object ...");
	unlock(mResetMutex);
	startThread_return: skip;
}

inline evalSystemJs() /* ScriptEngineWorker::evalSystemJs */
{
	if /* QFile::exists(systemJsPath) */
	::
		/* FileUtils::readFromFile(const QString &fileName) */
		if /* (!file.isOpen()) */
		:: throw(FailedToOpenFileException); catch ? returnControl; /* catch ? returnControl; необходим для возврата управления */
		:: skip;
		fi;
		if /* (engine->hasUncaughtException()) */
		:: skip;
		:: LOG("ERROR: system.js: Uncaught exception at line ...");
		fi;
	:: LOG("ERROR: system.js not found, path: ...");
	fi;
	/* finite cycle removed */
}

inline removePostedEvents(queue) /* очистить посланные события из очереди событий \a queue */
{
	atomic {
		mtype temp;
		do
		:: nempty(queue) -> queue ? temp;
		:: empty(queue) -> break;
		od;
	};
}
/* проверяем события \a reqSignal, которые могли быть посланы в \a reqQueue, но каким-то причинам не обработаны, а должны быть */
inline checkUnhandledSignals(reqSignal, reqQueue) 
{
	atomic {
		mtype temp;
		do
		:: empty(reqQueue) -> break;
		:: nempty(reqQueue) ->
			reqQueue ? temp;
			if
			:: temp == reqSignal -> //assert(false); временный "фикс" в самой модели - мы как-бы фильтруем события, которые были вызываны до коннектов
			:: else -> tmpQueue ! temp;
			fi;
		od;
		do /* если дошли сюда, значит, мы проверили, что всё ок */
		:: empty(tmpQueue) -> break;
		:: nempty(tmpQueue) ->
			tmpQueue ? temp;
			reqQueue ! temp;
		od;
	};
}

proctype sensorsThread() /* на самом деле существует много отдельных потоков для различных сенсоров */
{
	mtype signal;
	end: progress: do
	:: sensorsThreadEvents ? signal ->
		if
		:: signal == emptyEvent -> skip;
	    fi;
	od;
}

proctype connectionThread() /* обслуживание клиента TrikCommunicator, обработка сообщений */
{
	mtype signal;
	end: progress: do
	:: connectionThreadEvents ? signal ->
		if
		:: signal == emptyEvent -> skip;
	    fi;
	od;
}

proctype engineThread(byte id) /* id остаётся одинаковым на всё время жизни треда */
{
	chan tmpQueue = [N] of {mtype}; /* необходимый для моделирования и проверок канал */
	mtype signal;
	do // возможно, стоит смоделировать без цикла
	:: engineThreadEvents[id] ? signal ->
		if
		:: signal == start -> /* ScriptThread::run() */
			LOG("Started thread ScriptThread");
			evaluate_call: skip; /* mEngine->evaluate(mScript) --- скрипт внутри может вызвать новые потоки, убивать... */
			// assert(!abortEvaluationInvoked[id]); временно закомментировали, ибо в модели никак не отражается ограничение в реальной системе
			/* аборт исполнения скрипта до самого исполнения может привести к краху программы */
			/* progress в данном месте, так как может быть бесконечный цикл для автоматизированной системы */
			progress: do /* в данной модели забиваем тут на brick, gamepad, mailbox из createScriptEngine */
			:: !abortEvaluationInvoked[id] -> /* если не был вызван аборт исполнения скрипта */
				if
				//:: 
				//	evalSystemJs();
				//	copyRecursivelyTo: skip; /* рекурсивное копирование, знаем, что не бесконечное */
				//	evalSystemJs();
				//	startThread(); /* параметр моделируем через недетерминизм, кол-во тредов ограничиваем сами или run()-ом */
				//:: joinThread(id); /* параметр моделируем через недетерминизм */
				//:: killThread(); /* параметр моделируем через недетерминизм */
				// :: sendMessage();
				// :: receiveMessage();
				//:: script_quit();
				:: script_run();
				//:: script_wait(); // вообще можно проверить свойства, что в скрипте можно написать хрень, из-за которой что-то произойдет O_o
				// WARNING: можно испускать сигналы из ScriptExecutionControl.
				:: break; /* конец скрипта */
				fi;
			:: else -> break;
			od;
			evaluate_return: skip;
			if /* mEngine->hasUncaughtException() */
			:: mErrorMessage -> LOG("Uncaught exception at line ..."); // изменили модель, добавив проверку на непустоту mErrorMessage чтоб "поправить ошибку"
			:: else ->
				if
				:: mInEventDrivenMode -> 
					atomic {
						checkUnhandledSignals(stopRunning, engineThreadEvents[id]); /* здесь вызывается необходимый коннект, проверим, что эмитов, нужных после, до этого не было */
						isAutonomousCycle[id] = true; engineThreadEvents[id] ? stopRunning; isAutonomousCycle[id] = false; /* пойдет дальше, если stopRunning был испущен */
					};
				:: else -> skip;
				fi;
			fi;
			// mEngine->deleteLater(). можно послать соответствующий сигнал. который на обработке просто поставит метку deleted. - вообще мб удаление именно стоит проверить?
			/* Threading::threadFinished(...) */
			LOG("Finishing thread ...");
			lock(mResetMutex);
			lock(mThreadsMutex);
			if
			:: mErrorMessage = true; /* в таком случае мы можем не показать важную ошибку, если она произошла в другом потоке */
			:: skip;
			fi;
			LOG("Thread ... has finished, thread object ...");
			atomic {
				mThreads[id] = 0; 
				findFreeThreadId();
				removePostedEvents(engineThreadEvents[id]);
				// assert(empty(engineThreadEvents[id])); 
				// NOTE: это ведь плохо, если перед удалением у нас висят какие-то ивента в ивентлупе?...
				// но, возможно, нет. так как они мб не обрабатываются. тогда нужно тут очищать очередь. (это сейчас реализовано)
				mThreadCount--;
			};
			mFinishedThreads[id] = 1; // FIXME: тут если в цикле создаются треды и тут же удаляются?
			unlock(mThreadsMutex);
			unlock(mResetMutex);
			if /* !mErrorMessage.isEmpty() */
			:: mErrorMessage -> threading_reset();
			:: else -> skip;
			fi;
			LOG("Ended evaluation, thread ...");
			goto exit; /* испускается finished(), вызывается удаление, а остальные сигналы не обрабатываются */
		:: signal == stopRunning ->
			assert(false); /* не должен быть сигнал stopRunning до старта */
	    fi;
	od;
	exit: skip;
	assert(empty(engineThreadEvents[id])); /* логично, если "лишних" сигналов не будет */
}

proctype scriptWorkerThread()
{
	mtype signal;
	end: progress: do /* end, так как mWorkerThread удаляется при закрытии всей программы */
	:: scriptWorkerThreadEvents ? signal ->
		if 
		:: signal == INVOKEdoRun ->
			doRunInvoked: mErrorMessage = false;
			clear(mFinishedThreads, S);
			clear(mPreventFromStart, S);
			timerTimeout = false; /* не забываем скинуть в начальное состояние все флаги в модели на момент исполнения */
			loopStopWaiting = false; /* не забываем скинуть в начальное состояние все флаги в модели на момент исполнения */
			clear(isAutonomousCycle, S); /* не забываем скинуть в начальное состояние все флаги в модели на момент исполнения */
			evalSystemJs();
			startThread();
			mState = running;
			waitForAll_call: skip;
			mThreadCount == 0 -> /* нужно понимать, что удаляется тред, испуская finished() чуть позже изменения числа тредов и хэша */
			waitForAll_return: skip;
			LOG("ScriptEngineWorker: evaluation ended with message: empty or error");
			completedEmitted: emit(GUIThreadEvents, completed); /* также данный сигнал посылвает уведомление на виджет, что мы смоделируем косвенно в GUIThread */
		fi;
	od;
}

proctype GUIThread()
{
	mtype signal;
	end: progress: do /* end и progress - так как считаем, что программа всегда работает и не выключается */
	:: GUIThreadEvents ? signal -> /* расписываем ВСЕ возможные сигналы для каждого потока */
		if
		:: signal == runScript -> 
			LOG("TrikGui started");
//			run connectionThread(); /* создается с backgroundwidget */
//			run sensorsThread(); /* создается с brick */
			// подумать, что делать с удалением через signal finished
			// тут достаточно коннектов в конструкторе, которые стоит включить
			LOG("Starting TrikScriptRunner worker thread");
			run scriptWorkerThread();
			/* TrikScriptRunner::run */
			LOG("TrikScriptRunner: new script");
			/* вызывается mScriptEngineWorker->stopScript() */
			stopScript();
			/* startScriptEvaluation */
			LOG("ScriptEngineWorker: starting script");
			mState = starting;
			/* emit startedScript(mScriptId); --- выпускаем, так как он не должен влиять на работу модели */
			atomic {
				threadId = 0; 
				clear(abortEvaluationInvoked, S);
				emit(scriptWorkerThreadEvents, INVOKEdoRun);
			};
		:: signal == completed ->
			/* моделируем в следующих 4 строчках сигнал showError(...) */
			if
			:: mErrorMessage -> 
				mErrorMessage = false; /* = false, ибо тут важно, что сообщение показано, а в модели не важно, что с mErrorMessage дальше */
				showError: skip; 
			:: else -> skip;
			fi;
			
			if
			:: true -> hideRunningWidgetSignal: skip;
			:: true -> sendMessages: skip; showErrorSignal: skip; /* по всем открытым соединениям вещается об ошибке */
			fi;
			brick_reset();
//		:: signal == completed ->
//			goto app_quit; /* connect(&result, SIGNAL(completed(QString, int)), &app, SLOT(quit())); */
		:: signal == abortScript ->
			stopScript();
			LOG("Stopping robot");
			brick_reset();
	    fi;
	od;
	app_quit: skip; // наверно, стоит смоделировать удаление scriptWorkerThread
	// можно сделать 3 проверки: что конца в любом случае программа достигнет (метки app_quit)
	// и вторая проверка связана с signal == completed, который должен недетерменированно выбраться.
	// ещё проверка связана с тем, что все остальные процессы достигли конца..
}

proctype User() /* процесс, который моделирует возможные вызовы методов в trikScriptRunner */
{
	end: progress: do
	:: emit(GUIThreadEvents, runScript); // точно ли надо через эмиты? может, глобальные переменные - как доставляется сигнал? и подумать, надо ли возвращаться к дефолтным значениям.
	:: emit(GUIThreadEvents, abortScript);
	od;
}

proctype ExceptionHandler() /* процесс, который моделирует обработку исключений */
/* второй способ моделирования --- переходить по меткам goto внутри proctype */
{
	end: progress: do
	::
		if
		:: catch ? FailedToOpenFileException ->
			// assert(false); меняем модель, сейчас как-будто обработка есть.
			catch ! returnControl; /* необходимо для возврата управления в нужную точку программы */
		fi;
	od;
}

proctype Timer()
{
	timerTimeout = true;
}

init
{
	//run User();
	run ExceptionHandler();
	run GUIThread();
	emit(GUIThreadEvents, runScript);
}

never  {    /* ![](p2-><>q2 || <>[]r2) */
T0_init:
        do
        :: (! ((q2)) && ! ((r2)) && (p2)) -> goto accept_S4
        :: (! ((q2)) && (p2)) -> goto T0_S4
        :: (1) -> goto T0_init
        od;
accept_S4:
        do
        :: (! ((q2))) -> goto T0_S4
        od;
T0_S4:
        do
        :: (! ((q2)) && ! ((r2))) -> goto accept_S4
        :: (! ((q2))) -> goto T0_S4
        od;
}