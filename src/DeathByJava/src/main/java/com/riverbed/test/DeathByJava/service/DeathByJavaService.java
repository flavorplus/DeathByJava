
package com.riverbed.test.DeathByJava.service;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

@Component
public class DeathByJavaService {

	public String createLoad(Integer number) {
		return "Hello Andre!! The number is:" + number;
	}

}
