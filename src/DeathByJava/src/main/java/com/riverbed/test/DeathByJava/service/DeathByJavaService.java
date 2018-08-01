
package com.riverbed.test.DeathByJava.service;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.Random;

@Component
public class DeathByJavaService {

	private Random rng = new Random();

	public String createLoad(Integer number) {
		long startTime = System.currentTimeMillis();

		for (int i = 0; i < (number*100); i++){
			double r = rng.nextFloat();
			double v = Math.sin(Math.cos(Math.sin(Math.cos(r))));
		}

		long runTime = System.currentTimeMillis() - startTime;

		String output = String.format("Hello Jon!! The number of itterations was: %d The run time was:%dms", number, runTime);

		return output;
	}
}
